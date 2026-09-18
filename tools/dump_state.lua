-- Dump the video state Cadash's frame was drawn from, plus MAME's own output
-- for that frame, so tools/render_model.py can be checked against it pixel for
-- pixel.
--
--   DUMPFRAMES=600,900 DUMP_DIR=ref/states COIN=.. START=.. \
--     tools/mame.sh -seconds_to_run 40 -autoboot_script tools/dump_state.lua
--
-- One binary file per frame, little-endian:
--   magic "CDST", u32 version=2, u32 frame
--   u16 scn_ctrl[8]          C20000..C2000F
--   u16 scn_ram[32768]       C00000..C0FFFF
--   u16 spr_ram[1024]        B00000..B007FF, the 256-entry active table
--   u16 spr_ctrl             shadow of the write-only register at 080000
--   u16 oj_ctrl              sprite RAM word 0xDFF, the PC090OJ flip register
--   u16 palette[4096]        shadow of TC0110PCR RAM, tracked from boot,
--                            taken at the frame MAME *displays* the picture
--   u32 pixels[240][320]     MAME's own output for that frame
--
-- MAME's video pipeline runs a frame behind the Lua callback, and the PC090OJ
-- buffers its sprite table for a further frame, both of which this script
-- undoes.  Measured, not assumed: on a 304-frame static stretch of the attract
-- mode the renderer matches MAME exactly, and on moving frames it matches only
-- with the two-stage delay below.  What screen:pixels() returns at callback N
-- was drawn from the tilemap state at callback N-1 and the sprite table at
-- callback N-2.
--
-- Every callback and tap is held in a GLOBAL.  MAME's Lua bindings keep only a
-- weak hold on them and the chunk's locals die when the script returns, so a
-- callback in a local stops firing a few hundred frames in, silently.

g_mac    = manager.machine
g_sp     = g_mac.devices[":maincpu"].spaces["program"]
g_screen = g_mac.screens[":screen"]
g_dir    = os.getenv("DUMP_DIR") or "ref/states"
os.execute("mkdir -p '" .. g_dir .. "'")

g_want = {}
for n in string.gmatch(os.getenv("DUMPFRAMES") or "600", "%d+") do
  g_want[tonumber(n)] = true
end
g_coin  = tonumber(os.getenv("COIN")  or "0")
g_start = tonumber(os.getenv("START") or "0")
-- FREEZE=<frame> holds the sprite table still from that frame on, by writing
-- the captured table back every frame.  The PC090OJ's buffer then holds the
-- same values whatever the pipeline delay is, which is how the sprite path is
-- validated against MAME without depending on that delay at all.
g_freeze = tonumber(os.getenv("FREEZE") or "0")
g_frozen = nil
-- BLANK=<frame> forces TC0100SCN ctrl[6] from that frame on, so a chosen set
-- of tilemap layers can be isolated (CTRL6 picks the value, default 0x2F =
-- all three off); PARK=<frame> moves every sprite off screen.  Between them
-- each layer can be checked against MAME on its own.
g_blank = tonumber(os.getenv("BLANK") or "0")
g_park  = tonumber(os.getenv("PARK")  or "0")
g_ctrl6 = tonumber(os.getenv("CTRL6") or "0x2f")

-- Write-only registers have to be shadowed: the CPU can never read them back
-- and neither can Lua.  The palette shadow is exact because palette RAM comes
-- up zeroed and every write goes through these two ports.
g_taps     = {}
g_spr_ctrl = 0
g_pal      = {}
for i = 0, 4095 do g_pal[i] = 0 end
g_pal_addr = 0

g_taps[#g_taps+1] = g_sp:install_write_tap(0x080000, 0x080003, "sprctl",
  function(o, d, m) if o < 0x080002 then g_spr_ctrl = d & 0xffff end end)
g_taps[#g_taps+1] = g_sp:install_write_tap(0xa00000, 0xa0000f, "pcr",
  function(o, d, m)
    local reg = (o - 0xa00000) // 2
    if reg == 0 then g_pal_addr = d & 0xfff
    elseif reg == 1 then g_pal[g_pal_addr] = d & 0xffff end
  end)

function words(base, count)
  local t = {}
  for i = 0, count - 1 do
    t[#t+1] = string.pack("<I2", g_sp:read_u16(base + i * 2) & 0xffff)
  end
  return table.concat(t)
end

function snapshot()
  local pal = {}
  for i = 0, 4095 do pal[#pal+1] = string.pack("<I2", g_pal[i]) end
  return {
    ctrl     = words(0xc20000, 8),
    scn      = words(0xc00000, 32768),
    spr      = words(0xb00000, 1024),
    spr_ctrl = g_spr_ctrl,
    oj_ctrl  = g_sp:read_u16(0xb00000 + 0xdff * 2) & 0xffff,
    pal      = table.concat(pal),
  }
end

function dump(frame, tile, spr)
  local f = assert(io.open(string.format("%s/f%06d.bin", g_dir, frame), "wb"))
  f:write("CDST", string.pack("<I4I4", 2, frame))
  f:write(tile.ctrl, tile.scn, spr.spr)
  f:write(string.pack("<I2I2", tile.spr_ctrl, tile.oj_ctrl))
  local pal = {}
  for i = 0, 4095 do pal[#pal+1] = string.pack("<I2", g_pal[i]) end
  f:write(table.concat(pal))
  local px = g_screen:pixels()
  f:write(px)
  f:close()
end

g_frames = 0
g_prev1, g_prev2 = nil, nil

function hold(port, field, from)
  g_mac.ioport.ports[port].fields[field]
    :set_value((from > 0 and g_frames >= from and g_frames < from + 8) and 1 or 0)
end

g_done_cb = function()
  g_frames = g_frames + 1
  if g_coin  > 0 then hold(":IN2", "Coin 1", g_coin) end
  if g_start > 0 then hold(":IN2", "1 Player Start", g_start) end

  if g_freeze > 0 and g_frames >= g_freeze then
    if g_frozen == nil then
      g_frozen = {}
      for i = 0, 1023 do g_frozen[i] = g_sp:read_u16(0xb00000 + i * 2) & 0xffff end
    else
      for i = 0, 1023 do g_sp:write_u16(0xb00000 + i * 2, g_frozen[i]) end
    end
  end

  if g_blank > 0 and g_frames >= g_blank then
    g_sp:write_u16(0xc2000c, g_ctrl6)
  end
  if g_park > 0 and g_frames >= g_park then
    for i = 0, 255 do
      g_sp:write_u16(0xb00000 + i * 8 + 2, 0x01f0)   -- Y well below the screen
    end
  end

  if g_want[g_frames] and g_prev1 and g_prev2 then
    dump(g_frames, g_prev1, g_prev2)
  end
  -- Snapshotting is expensive, so only keep the two frames a wanted dump needs.
  g_prev2 = g_prev1
  if g_want[g_frames + 1] or g_want[g_frames + 2] then
    g_prev1 = snapshot()
  else
    g_prev1 = nil
  end
end
emu.register_frame_done(g_done_cb)
