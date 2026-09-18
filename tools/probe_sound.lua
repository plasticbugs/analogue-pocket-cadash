-- What the sound Z80 asks the YM2151 for, and when.
--   COIN=<frame> REPORT=<frame> OUT=<file> tools/mame.sh -seconds_to_run N \
--     -autoboot_script tools/probe_sound.lua
-- Callbacks and taps live in globals; see tools/probe_regs.lua.
g_out = assert(io.open(os.getenv("OUT") or "tmp/sound.txt", "w"))
function say(s) g_out:write(s .. "\n"); g_out:flush() end

g_z80  = manager.machine.devices[":audiocpu"].spaces["program"]
g_taps = {}
g_reg  = 0
g_writes, g_keyon, g_reg1b, g_bank = 0, 0, 0, 0
g_first_keyon = -1
g_frames = 0

g_taps[#g_taps+1] = g_z80:install_write_tap(0x9000, 0x9001, "ym", function(o, d, m)
  g_writes = g_writes + 1
  if o == 0x9000 then
    g_reg = d & 0xff
    if g_reg == 0x1b then g_reg1b = g_reg1b + 1 end
  else
    if g_reg == 0x08 and (d & 0x78) ~= 0 then
      g_keyon = g_keyon + 1
      if g_first_keyon < 0 then g_first_keyon = g_frames end
    end
    if g_reg == 0x1b then g_bank = d >> 6 end
  end
end)

-- the Z80's side of the PC060HA: the mode it selects and what it does with it
g_submode, g_nmi_en, g_nmi_dis, g_slave_wr, g_slave_rd = 0, 0, 0, 0, 0
g_taps[#g_taps+1] = g_z80:install_write_tap(0xa000, 0xa001, "ciu_s",
  function(o, d, m)
    if o == 0xa000 then
      g_submode = d & 0x0f
    else
      g_slave_wr = g_slave_wr + 1
      if g_submode == 6 then g_nmi_en  = g_nmi_en  + 1 end
      if g_submode == 5 then g_nmi_dis = g_nmi_dis + 1 end
    end
  end)

-- what the 68000 sends the sound board, for comparison with the core's own count
g_m68k = manager.machine.devices[":maincpu"].spaces["program"]
g_ciu  = 0
g_taps[#g_taps+1] = g_m68k:install_write_tap(0x0c0000, 0x0c0003, "ciu",
  function(o, d, m) g_ciu = g_ciu + 1 end)

g_coin   = tonumber(os.getenv("COIN")   or "120")
g_report = tonumber(os.getenv("REPORT") or "200")

g_cb = function()
  g_frames = g_frames + 1
  manager.machine.ioport.ports[":IN2"].fields["Coin 1"]
    :set_value((g_frames >= g_coin and g_frames < g_coin + 10) and 1 or 0)
  if g_frames == g_report then
    say(string.format("frames %d: %d YM writes, %d key-ons (first at frame %d)",
        g_frames, g_writes, g_keyon, g_first_keyon))
    say(string.format("register 0x1B written %d times, bank now %d", g_reg1b, g_bank))
    say(string.format("68000 writes to the PC060HA: %d", g_ciu))
    say(string.format("Z80 CIU writes %d; NMI enabled %d times, disabled %d",
        g_slave_wr, g_nmi_en, g_nmi_dis))
  end
end
g_sub = emu.register_frame_done(g_cb)
