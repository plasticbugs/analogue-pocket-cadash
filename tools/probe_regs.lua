-- Report what Cadash writes to its video chips, and when.
--   REPORT=<frame> COIN=<frame> START=<frame> OUT=<file> \
--     tools/mame.sh -seconds_to_run N -autoboot_script tools/probe_regs.lua
--
-- NOTE: every callback and tap is held in a GLOBAL.  MAME's Lua bindings keep
-- only a weak hold on them, and the chunk's own locals become collectable the
-- moment the autoboot script returns, so a callback stored in a local stops
-- firing a few hundred frames in, silently.

g_out  = assert(io.open(os.getenv("OUT") or "tmp/probe_regs.txt", "w"))
function say(s) g_out:write(s .. "\n"); g_out:flush() end

g_sp     = manager.machine.devices[":maincpu"].spaces["program"]
g_taps   = {}
g_ctrl   = {}   -- [reg] -> { [value] = count }
g_sprctl = {}
g_ojctrl = {}
g_pal    = {}
g_pal_addr, g_pal_min, g_pal_max, g_pal_writes = 0, 4096, -1, 0
g_share_w = 0

function note(t, k, v)
  t[k] = t[k] or {}
  t[k][v] = (t[k][v] or 0) + 1
end

g_taps[#g_taps+1] = g_sp:install_write_tap(0xc20000, 0xc2000f, "scnctrl",
  function(o, d, m) note(g_ctrl, (o - 0xc20000) // 2, d & 0xffff) end)
g_taps[#g_taps+1] = g_sp:install_write_tap(0x080000, 0x080003, "sprctl",
  function(o, d, m) note(g_sprctl, (o - 0x080000) // 2, d & 0xffff) end)
g_taps[#g_taps+1] = g_sp:install_write_tap(0xb01bfe, 0xb01bff, "ojctrl",
  function(o, d, m) note(g_ojctrl, 0, d & 0xffff) end)
g_taps[#g_taps+1] = g_sp:install_write_tap(0xa00000, 0xa0000f, "pcr",
  function(o, d, m)
    local reg = (o - 0xa00000) // 2
    if reg == 0 then
      g_pal_addr = d & 0xfff
    elseif reg == 1 then
      g_pal[g_pal_addr] = d & 0xffff
      g_pal_writes = g_pal_writes + 1
      if g_pal_addr < g_pal_min then g_pal_min = g_pal_addr end
      if g_pal_addr > g_pal_max then g_pal_max = g_pal_addr end
    end
  end)
g_taps[#g_taps+1] = g_sp:install_write_tap(0x800000, 0x800fff, "sharew",
  function(o, d, m) g_share_w = g_share_w + 1 end)

function dumpset(name, t)
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local vs = {}
    for v, n in pairs(t[k]) do vs[#vs+1] = string.format("%04x:%d", v, n) end
    table.sort(vs)
    say(string.format("%s[%d] = %s", name, k, table.concat(vs, " ")))
  end
end

g_frames = 0
g_coin   = tonumber(os.getenv("COIN")  or "0")
g_start  = tonumber(os.getenv("START") or "0")
g_report = tonumber(os.getenv("REPORT") or "600")

function hold(port, field, from)
  manager.machine.ioport.ports[port].fields[field]
    :set_value((from > 0 and g_frames >= from and g_frames < from + 8) and 1 or 0)
end

g_frame_cb = function()
  g_frames = g_frames + 1
  if g_coin  > 0 then hold(":IN2", "Coin 1", g_coin) end
  if g_start > 0 then hold(":IN2", "1 Player Start", g_start) end
  if g_frames == g_report then
    say(string.format("--- report at frame %d ---", g_frames))
    dumpset("scn_ctrl", g_ctrl)
    dumpset("spr_ctrl", g_sprctl)
    dumpset("oj_ctrl",  g_ojctrl)
    say(string.format("palette: %d writes, idx %d..%d", g_pal_writes, g_pal_min, g_pal_max))
    say(string.format("shared RAM writes: %d", g_share_w))
  end
end
g_sub = emu.add_machine_frame_notifier(g_frame_cb)
