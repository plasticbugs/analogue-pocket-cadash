-- Measure the sprite load: how many of the 256 entries are on screen, and the
-- worst number overlapping a single scanline.  The second number is the one
-- the core's line renderer has to fit in a scanline's worth of clocks.
--   OUT=tmp/sprites.txt COIN=.. START=.. tools/mame.sh -seconds_to_run N \
--     -autoboot_script tools/probe_sprites.lua
-- Callbacks live in globals; see tools/probe_regs.lua.
g_sp  = manager.machine.devices[":maincpu"].spaces["program"]
g_out = assert(io.open(os.getenv("OUT") or "tmp/sprites.txt", "w"))
g_n = 0
g_best_line, g_best_line_frame = 0, 0
g_best_scr,  g_best_scr_frame  = 0, 0
g_hist = {}

g_cb = function()
  g_n = g_n + 1
  if g_n < 150 then return end   -- sprite RAM is uninitialised until the game clears it
  local rows = {}
  for i = 0, 271 do rows[i] = 0 end
  local on = 0
  for e = 0, 255 do
    local base = 0xb00000 + e * 8
    local y = g_sp:read_u16(base + 2) & 0x1ff
    local x = g_sp:read_u16(base + 6) & 0x1ff
    if y > 0x140 then y = y - 0x200 end
    if x > 0x140 then x = x - 0x200 end
    y = y + 8
    if x > -16 and x < 320 and y > 0 and y < 256 then
      on = on + 1
      for r = math.max(y, 16), math.min(y + 15, 255) do
        rows[r] = rows[r] + 1
      end
    end
  end
  local worst = 0
  for r = 16, 255 do if rows[r] > worst then worst = rows[r] end end
  if worst > g_best_line then g_best_line, g_best_line_frame = worst, g_n end
  if on > g_best_scr then g_best_scr, g_best_scr_frame = on, g_n end
  g_hist[#g_hist+1] = { worst, on, g_n }
  if g_n == tonumber(os.getenv("REPORT") or "4500") then
    table.sort(g_hist, function(a, b) return a[1] > b[1] end)
    g_out:write(string.format("peak: %d sprites on screen (frame %d), %d overlapping one line (frame %d)\n",
      g_best_scr, g_best_scr_frame, g_best_line, g_best_line_frame))
    g_out:write("busiest frames by sprites per line:\n")
    local seen = {}
    local shown = 0
    for _, h in ipairs(g_hist) do
      if shown >= 12 then break end
      local bucket = h[3] // 60
      if not seen[bucket] then
        seen[bucket] = true
        shown = shown + 1
        g_out:write(string.format("  frame %5d: %3d per line, %3d on screen\n", h[3], h[1], h[2]))
      end
    end
    g_out:flush()
  end
end
emu.register_frame_done(g_cb)
