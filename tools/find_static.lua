-- Report frames whose whole video state is unchanged from the frame before,
-- so the frozen-state bench can use states where MAME's own pipeline delay
-- cannot matter.  Held in globals; see tools/probe_regs.lua.
g_out = assert(io.open(os.getenv("OUT") or "tmp/static.txt", "w"))
g_sp  = manager.machine.devices[":maincpu"].spaces["program"]
g_n, g_run, g_prev = 0, 0, nil

function sig()
  local h = 0
  for a = 0xc00000, 0xc0fffe, 2 do h = (h * 31 + g_sp:read_u16(a)) & 0xffffffff end
  for a = 0xb00000, 0xb007fe, 2 do h = (h * 31 + g_sp:read_u16(a)) & 0xffffffff end
  for a = 0xc20000, 0xc2000e, 2 do h = (h * 31 + g_sp:read_u16(a)) & 0xffffffff end
  return h
end

g_cb = function()
  g_n = g_n + 1
  local s = sig()
  if s == g_prev then g_run = g_run + 1 else
    if g_run >= 3 then
      g_out:write(string.format("static run ending at frame %d, length %d\n", g_n - 1, g_run + 1))
      g_out:flush()
    end
    g_run = 0
  end
  g_prev = s
end
emu.register_frame_done(g_cb)
