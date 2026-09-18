# What is checked, by what, and what each check is worth

Three gates, each cheaper than the one below it and each checking something
the others cannot.

---

## 1. The ROM path — seconds

    tools/dump_regions.lua   writes the bytes MAME loads into each chip
    tools/verify_rom.py      diffs them against the image cadash.mra builds

Every region matches byte for byte. That is what establishes the `map="21"`
byte swap on the two graphics ROMs is the right way round; get it wrong and
every tile is garbage in a way that looks like a renderer bug.

`tools/mra_build.py` additionally CRC-checks every part as it reads the
romset and checks the finished image against an md5 recorded in the .mra, so
a wrong or damaged romset is reported rather than quietly built.

---

## 2. The reference renderer against MAME — under a second per state

    tools/regress_render.sh

For each of the ten states in `ref/states`, `tools/render_model.py` reads the
dumped video state and produces a 320x240 frame, and the script diffs it
against MAME's own output for that frame. **Zero differing pixels on every
state.**

This is the gate that matters most, because everything below it is checked
against the renderer rather than against MAME. Two things make it honest:

* the states are chosen for coverage, not convenience: the title screen, four
  points of the attract demo, and the frames with the heaviest sprite load
  anywhere in a 75-second survey (frame 859 puts 67 sprites on one scanline,
  frame 2597 puts 145 on the screen);
* the state files are not committed. `tools/dump_states.sh` regenerates them
  from the user's own romset in about a minute, so the gate cannot quietly
  rot against a stale capture.

Three properties of MAME's own pipeline have to be undone to read its output
at all; `docs/hardware.md` section 10 says what they are and how each was
measured.

---

## 3. The video RTL against the reference renderer — about a second per state

    sim/run_video.sh

Loads a dumped state into `rtl/cadash_video.sv` through the chips' own
CPU-side ports, renders a frame in Verilator and diffs the palette indices
against the renderer's. **Zero differing indices on every state**, which
makes the RTL pixel-identical to MAME on them.

It also reports the worst line's clock count, so a change that is correct but
too slow is caught in the same run. `LAT=n` sets the modelled graphics-ROM
latency: the renderer still fits at 20 clocks and runs out of time somewhere
around 25, which is the number the SDRAM controller has to beat.

Comparing **indices** rather than colours is deliberate: it keeps the video
test independent of the palette conversion, so a palette bug cannot mask a
renderer bug or the other way round.

---

## 4. The whole machine — minutes

    sim/run_system.sh

Both CPUs run the real program against a model of the Pocket's SDRAM. This is
slow -- a frame is 1.6 million clocks -- so it answers questions about the
machine rather than about the picture: does it boot, do the interrupts run,
does the sound CPU answer.

It reports: whether the 68000 ever halted, how many vblank interrupts it
took, PC060HA traffic in both directions, the Z80's RAM and YM2151 writes,
the worst line, and the addresses the 68000 spent its bus cycles on. It also
keeps a shadow of main RAM and reports any read that does not return what was
written.

That last check is what found the first real bug in the CPU side: the 68000
hung in its boot self-test printing WORK RAM ERROR because `sel_ram` compared
against `9'b0_0001_0000`, which is 0x080000 rather than 0x100000. The
address histogram put the hang at 0x0F22, and the `LEA` two instructions
earlier pointed at the message table at 0x0DB3. Neither the ROM gate nor
either video gate could have seen it.

---

## 5. What none of this covers

* **Sound has not been compared with MAME at all.** The YM2151 is
  instantiated and the Z80 writes to it; nothing yet says the output matches.
  METHODOLOGY section 5.3 applies: find out what paces the audio first. Here
  it is the chip's own clock, not the CPU, so a stalled Z80 costs tempo only
  if it misses a command.
* **The core has never run on hardware.** Quartus 18.1 builds it, but the
  SDRAM timing, the video hand-off and the controls are all unproven outside
  simulation.
* **Clock-domain crossings.** There is one multi-bit crossing, the audio
  sample into the Pocket's filter domain, and it is handled the way
  METHODOLOGY section 5.4 says to: sampled at 48 kHz, held, handed over with
  a toggle. It has not been exercised on hardware.
