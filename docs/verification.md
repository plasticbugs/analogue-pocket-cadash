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

## 4a. The sound chip on its own — seconds

    sim/run_ym.sh

A YM2151 with nothing around it, driven with the core's own clock enables and
the core's own held write.  It sets CT1 and CT2 -- which on this board are the
Z80's ROM bank -- and plays one note.

This exists because the whole-machine bench could not answer the question it
was being asked. It could say the Z80 wrote the chip fifty thousand times and
nothing came out; it could not say whether the fault was the sound driver or
the way the core presents a write. Ten seconds of this said the chip was fine,
which turned the search around.

---

## 4b. The sound CPU against MAME's — seconds

    tools/probe_sound.lua

Counts, on the MAME side, what the sound Z80 asks the YM2151 for: total
writes, key-ons and when the first one happens, how often it selects register
0x1B (the bank), and what the 68000 sends the comms unit. `sim/run_system.sh`
counts the same things on the core side, so the two can be put side by side.

That comparison is what found the PC060HA read bug. Over 200 frames with a
coin at frame 120:

| | MAME | the core, before |
|---|---|---|
| YM2151 writes | 47,310 | 49,100 |
| key-ons | 22, first at frame 139 | **0** |
| 68000 -> comms unit | 51 writes | comparable |

A driver running at the right rate and playing nothing is a driver being fed
the wrong data, which is what it was: reading the comms unit advances its
mode, and the Z80 samples its data bus at the *end* of a bus cycle, by which
time the strobe at the start had already moved the mode on. The 68000 side
had been written to capture the byte on the first clock; the Z80 side had
not.

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

---

## 6. The memory subsystem, and the hole it sat in

`sim/run_mem.sh` runs the real `target/pocket/cadash_mem.sv` and
`target/pocket/sdram_ctrl.sv` against a behavioural SDRAM chip, pushes the
whole 1,638,400-byte image in through the download port at the APF loader's
rate, and reads all 524,288 words back through the four core ports, comparing
each against the image.

It exists because everything above it did not cover any of that.
`sim/tb_system_top.sv` answers both CPUs out of plain arrays with a fixed
latency counter; it never instantiates the memory subsystem at all. So the
controller, its four-client arbiter and the download path that fills SDRAM had
no gate, and the core could pass every test in this document and still be
unable to boot on hardware -- which is exactly what happened.

What it caught the first time it ran: **3,535 of 524,288 words wrong**, every
one of them with the right low byte and a wrong high byte. The download held a
single pending word, and the even byte of the *next* word overwrote
`dl_word[15:8]` while the previous word was still waiting for its ack, so the
write that went out carried the next word's high byte. Which words were hit
depended on refresh and row-change timing, so each power-up corrupted a
different scatter of the ROM; on the panel that read as an illegal instruction
at a different address every time, and as a black screen when the damage
landed somewhere the game needed before it could draw its own error.

The rate matters, so the gate takes it as an argument. The loader delivers at
most one byte per 8 clocks; the write path is clean down to 4 and fails at 3,
so there is about 2x of margin, and that is the number to re-measure if the
SDRAM arbitration ever changes.

What it still does not cover: the window before `ready`, since the bench waits
for the controller to finish initialising before it starts sending. On the
Pocket the host's transfer begins milliseconds after the core loads and the
controller is ready 126 us in, so the window is not reachable in practice, but
it is untested rather than proven.

---

## 7. The menu must not restart the game

Two gates, because there were two things wrong and the first one found was not
the one that mattered.

**The pause.** `core_top.sv` ORed the Pocket's `pause_core` -- the menu being
open -- into the machine's reset, so the board sat in reset for as long as the
menu was up and booted from scratch when it closed. It is now a pause:
`rtl/clk_enables.sv` freezes the 68000's, the Z80's and the YM2151's dividers
and masks their enables with the same signal, so no phase is skipped or
doubled, while the dot clock and the renderer carry on and the picture stays
behind the menu. `sim/run_system.sh <rom> -frames 260 -pause 120 60` holds the
menu open for sixty frames in the middle of the boot and reports three things:
the 68000 read its reset vector once, it started no bus cycle while paused, and
the frame it reaches is still MAME's title screen.

**The switches.** `sim/run_interact.sh` checks that a DIP, extra-DIP or
service write resets the machine only when it changes the word held. This was
written first, on the theory that the Pocket rewrites the DIP register when the
menu closes and the platform code reset on any write. The logic was wrong as it
stood and the gate fails the old code four ways, but it was not the cause of
the restart: v0.1.2 shipped this fix alone and the game still restarted. The
gate proved the code did what was intended and said nothing about whether the
intention was aimed at the right thing. What would have caught it sooner is
listing every term in the reset equation before picking one.
