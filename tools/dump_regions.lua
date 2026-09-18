-- Write out the ROM regions exactly as MAME loads them, so tools/verify_rom.py
-- can check the image cadash.mra builds against them.
--   OUT_DIR=tmp/regions tools/mame.sh -seconds_to_run 1 \
--       -autoboot_script tools/dump_regions.lua
-- Callbacks are held in globals; see the note in tools/probe_regs.lua.
g_dir = os.getenv("OUT_DIR") or "tmp/regions"
os.execute("mkdir -p '" .. g_dir .. "'")

for _, tag in ipairs({ ":maincpu", ":audiocpu", ":tc0100scn", ":pc090oj", ":subcpu" }) do
  local r = manager.machine.memory.regions[tag]
  if r then
    local f = assert(io.open(g_dir .. "/" .. tag:sub(2) .. ".bin", "wb"))
    local chunk = {}
    for i = 0, r.size - 1 do
      chunk[#chunk+1] = string.char(r:read_u8(i))
      if #chunk == 8192 then f:write(table.concat(chunk)); chunk = {} end
    end
    if #chunk > 0 then f:write(table.concat(chunk)) end
    f:close()
  end
end
