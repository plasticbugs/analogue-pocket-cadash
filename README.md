# Cadash — Analogue Pocket core (openFPGA)

**Work in progress.** This is not a working core yet: there is no 68000, no
Z80, no YM2151, and no Pocket platform integration. What exists is the ROM
path, a reference renderer proven pixel-identical to MAME, and video RTL that
is being brought up against it. See "Status" below before expecting anything
to run.

Cadash (Taito, 1989) on Taito's "Asuka" hardware — MAME set `cadash` (World),
driver `taito/asuka.cpp`, main PCB `K1100528A`. A 320x240 horizontal
(`ROT0`) two-tilemap-plus-sprites board: 68000 main CPU, Z80 + YM2151 sound,
TC0100SCN tilemaps, PC090OJ sprites, TC0110PCR palette, TC0220IOC I/O,
PC060HA sound communication. Twelve `cadash*` MAME sets exist; they differ
only in program ROM region/language and coinage, so this core (and its ROM
image) targets the World set and shares the rest.

> **ROMs are not included and never will be.** You supply your own MAME
> `cadash` romset; the core reads one image built from it.

## Status

| Board part | Implementation | Status |
|---|---|---|
| MC68000 @ 16 MHz (main CPU) | `rtl/cadash_main.sv` + fx68k | boots through the self-test to the title screen |
| Z80 @ 4 MHz (sound CPU) | `rtl/cadash_sound.sv` + TV80 | runs; banked through the YM2151's CT1/CT2 pins as the board does |
| YM2151 @ 4 MHz (FM) | `rtl/cadash_sound.sv` + JT51 | plays the same notes as MAME: same key-on count, same bank, peak within 0.3% |
| TC0100SCN (tilemaps + text) | `rtl/tilemap_line.sv` | renders every frozen state exactly as the MAME-verified reference does |
| PC090OJ (sprites) | `rtl/sprite_line.sv` | as above |
| TC0110PCR (palette) | `rtl/cadash_video.sv` | as above |
| TC0220IOC (inputs, DIPs, coin, watchdog) | `rtl/tc0220ioc.sv` | written from MAME's device |
| PC060HA (68000↔Z80 comms) | `rtl/pc060ha.sv` | carried over unchanged from the Master of Weapon core: MAME implements both boards' comms unit as one device |
| Video timing | `rtl/video_timing.sv` | 436×262 raster at 96/14 MHz, within 0.06% of the board's real rate |
| ROM image (1.6 MB) | `cadash.mra` + `tools/mra_build.py` | built and verified byte-for-byte against MAME's own loaded regions |
| HD64180 link CPU (two-cabinet link play) | — | not implemented, not planned — MAME itself cannot run it either |
| Pocket platform integration | `target/pocket/`, `platform/pocket/`, `pkg/pocket/` | Quartus 18.1 analysis and synthesis passes with no errors; never run on hardware |

What is actually proven, and how:

* **The reference renderer matches MAME exactly.** `tools/render_model.py`
  reads a state dumped from a running MAME and produces the same 320×240
  frame, pixel for pixel. `tools/regress_render.sh` checks this on ten frozen
  states spanning boot, attract, and the two frames with the heaviest sprite
  load found in a 75-second play survey — currently **0 of 76,800 pixels
  differ** on every state. This renderer is the executable spec the video RTL
  is written against; see `docs/hardware.md` for the semantics it captures
  (in particular the sprite priority rule, §7.3, and the scroll sign
  conventions, §9, both non-obvious and both traced to a specific line of
  MAME).
* **The ROM image is exactly what MAME loads.** `tools/verify_rom.py`
  compares the image `tools/mra_build.py` builds against the bytes MAME
  itself hands to each chip (dumped by `tools/dump_regions.lua`): identical.
* **The video RTL matches the reference renderer exactly.**
  `sim/run_video.sh` builds `rtl/` under Verilator, loads each of the ten
  frozen states through the video chips' own CPU-side ports, renders a frame
  and diffs the palette indices against the reference renderer: **0 of 76,800
  indices differ** on every state. Because the reference renderer is itself
  pixel-identical to MAME, that makes the video RTL pixel-identical to MAME
  on those states, including frame 859 with 67 sprites on one scanline and
  frame 2597 with 145 sprites on the screen.
* **The line budget has room.** The worst line in the state set costs 3,547
  of the 6,104 system clocks a scanline has, and the renderer still fits at a
  modelled graphics-ROM latency of 20 clocks (`docs/core-design.md` §5). That
  is the figure the SDRAM controller will have to beat once both CPUs are
  competing for it.
* **The whole machine reaches MAME's title screen, pixel for pixel.**
  `sim/run_boot.sh` runs both CPUs on the real program from reset for 150
  frames against a model of the Pocket's SDRAM and diffs the frame that comes
  out against MAME's: **byte-identical**. That is all four Taito customs, the
  memory map, both interrupts and the two CPUs together, checked against the
  oracle rather than against themselves. The comparison does not depend on
  the two machines counting frames the same way, because MAME holds the title
  screen still from frame 127 to frame 430.
* **The sound matches MAME.** `sim/run_sound.sh` inserts a coin on both sides
  at frame 120 and records 200 frames. Over that window MAME's sound board
  writes the YM2151 47,310 times and keys 22 notes; the core writes it 47,444
  times and keys the same 22. The peak sample is 8,928 against MAME's 8,954,
  and the worst per-second RMS difference is 4.3%. MAME's attract mode is
  genuinely silent for at least fourteen seconds, which is why the comparison
  needs a coin, and which the core matches.
* **It has never run on hardware.** Quartus 18.1 builds it, but no bitstream
  has been loaded on a Pocket, so nothing below simulation is proven: not the
  SDRAM timing, not the video hand-off, not the controls.

## What's here

| Path | What it is |
|---|---|
| `docs/hardware.md` | the board as MAME and the Lua probes describe it — chips, clocks, memory maps, DIPs, video registers, sprite format, the priority rule, and the three MAME quirks that have to be undone to read its output correctly |
| `docs/core-design.md` | how the core maps that onto the Pocket — clocks, the block-RAM/SDRAM split, the video pipeline's four render passes, the per-line clock budget |
| `cadash.mra` | ROM description: how the MAME romset's parts interleave into the image the core loads |
| `tools/mra_build.py` | dependency-free Python builder: MAME zip (or loose files) → ROM image, CRC32- and md5-checked |
| `tools/verify_rom.py` | compares the built image against MAME's own loaded regions |
| `tools/dump_regions.lua` | dumps those regions from a running MAME |
| `tools/render_model.py` | the reference renderer — MAME state → the exact frame MAME draws |
| `tools/dump_state.lua` | captures one frozen state (VRAM, sprite RAM, palette, MAME's own frame), with MAME's one-frame video lag and two-frame sprite-table lag undone |
| `tools/dump_states.sh` | captures the ten states in `ref/states/` |
| `tools/probe_regs.lua` | surveys what the game actually writes to the video chips over an attract-mode run |
| `tools/probe_sprites.lua` | measures sprite load per scanline and per frame, used to size the line renderer's budget |
| `tools/regress_render.sh` | gate: reference renderer vs MAME's own snapshots, all ten states |
| `tools/diff_index.py` | pixel/index diff with per-cell hotspot reporting, used by both regression scripts |
| `tools/fetch_refs.sh` | fetches the MAME source and the MiSTer Taito F2 clone this core reads (neither is vendored in this repository) |
| `rtl/video_timing.sv` | the TC0100SCN's raster, retuned for a 96 MHz system clock |
| `rtl/tilemap_line.sv` | TC0100SCN line renderer: BG0, BG1, text |
| `rtl/sprite_line.sv` | PC090OJ line renderer: 256 sprites, first-entry-wins priority |
| `rtl/cadash_video.sv` | the block RAM behind all of the above (tilemap VRAM, sprite RAM, palette) and the CPU-side ports into it |
| `sim/run_video.sh` | the frozen-state video bench: RTL vs the reference renderer |
| `ref/mame/` | MAME 0.288 source files this core was written against, fetched verbatim, read only, not compiled into the core |
| `ref/states/` | the ten frozen states `sim/run_video.sh` and `tools/regress_render.sh` run against |
| `METHODOLOGY.md` | the method: MAME as oracle, a reference renderer as executable spec, frozen-state benches as the regression gate |

## Building the ROM image

```sh
python3 tools/mra_build.py cadash.mra /path/to/cadash.zip
```

Needs nothing but Python 3. It reads the MAME zip (or a directory of loose
files) directly, checks every part's CRC32, and verifies the finished
1,638,400-byte image against the md5 recorded in `cadash.mra`, so a wrong or
damaged romset is reported rather than quietly built into something that
half works. The image is four regions with no padding between them — 68000
program, Z80 program, TC0100SCN tile graphics, PC090OJ sprite graphics — laid
out and commented in `cadash.mra` itself. `cadash.mra` is a standard MRA
description, so existing tools such as `pupdate` or the `mra` utility work
with it too.

There is nowhere to put the resulting image yet: there is no
`target/pocket/` or `Assets/` layout in this repository, because the Pocket
platform integration has not been started.

## Checking what's built

```sh
sh tools/regress_render.sh     # reference renderer vs MAME's own snapshots, ten states
sh sim/run_video.sh            # video RTL vs the reference renderer, same states
sh sim/run_boot.sh             # the whole machine from reset vs MAME's title screen
sh sim/run_sound.sh            # the coin sound, core vs MAME, second by second
sh sim/run_ym.sh               # the YM2151 alone, driven the way the core drives it
sh sim/lint.sh                 # every module linted on its own
```

`regress_render.sh` is pure Python; it builds a ROM image with
`tools/mra_build.py` if `tmp/cadash.rom` doesn't already exist (set `ROM=` to
point it elsewhere), then runs `tools/render_model.py` against every state in
`ref/states/` and reports pixel differences against MAME's own snapshot
embedded in each state file. `sim/run_video.sh` additionally needs
[Verilator](https://www.veripool.org/verilator/); it builds `rtl/`, loads
each frozen state through the video chips' own CPU-side ports, and diffs the
rendered palette indices against `render_model.py`'s output using
`tools/diff_index.py`. `sim/run_boot.sh` is the slow one: it runs both CPUs
for 150 frames, which is a quarter of a billion clocks and a few minutes, and
compares the frame the machine reaches with MAME's. `docs/verification.md`
says what each gate is worth and what none of them covers.

The ten states in `ref/states/` are **not** committed -- they are derived from
the user's own romset. `tools/dump_states.sh` captures them in about a
minute: it drives MAME
headless (`tools/mame.sh`) through `tools/dump_state.lua`, picking the
frames `tools/probe_sprites.lua` found interesting in a 75-second survey —
the title screen, several points in the attract loop, and the two frames
with the heaviest sprite load anywhere in the run (68 sprites on the worst
scanline, 145 on the worst screen).

## How this was built

`METHODOLOGY.md` is the method this core follows: MAME as the oracle you
interrogate rather than a reference you read, a reference renderer as the
executable spec, and frozen-state benches as the regression gate that
catches a video change before it reaches hardware. `docs/hardware.md` and
`docs/core-design.md` are the products of phases 1–3 of that method for this
board; `rtl/`, `sim/` and `target/` are phases 4 and 5. Phase 6, hardware,
has not begun.

## Credits

**[MAME](https://www.mamedev.org/)** was used throughout as the behavioural
oracle — not a reference to read, but a program interrogated with its Lua
interface (`tools/probe_regs.lua`, `tools/probe_sprites.lua`,
`tools/dump_state.lua`) to answer specific questions about what the real
hardware does. Every fact in `docs/hardware.md` and every rule in
`tools/render_model.py` is traced to a line of MAME's own source. The exact
files this core was written against are vendored verbatim and unmodified,
for reference only, in `ref/mame/` (fetched by `tools/fetch_refs.sh` from the
`mame0288` tag — **MAME 0.288** is the version used throughout); none of it
is compiled into the core.

* `src/mame/taito/asuka.cpp` — the Cadash driver (memory map, interrupts,
  clocks). BSD-3-Clause, copyright-holders **David Graves** and **Brian
  Troha**, thanks-to **Richard Bush**. The driver's own header credits its
  origin further: "Raine source - very special thanks to Richard Bush and
  the Raine Team."
* `src/mame/taito/tc0100scn.cpp` — the tilemap chip. BSD-3-Clause,
  copyright-holder **Nicola Salmoria**.
* `src/mame/taito/pc090oj.cpp` — the sprite chip, including the
  first-entry-wins priority rule this core implements
  (`rtl/sprite_line.sv`, `tools/render_model.py`). BSD-3-Clause,
  copyright-holder **Nicola Salmoria**.
* `src/mame/taito/tc0110pcr.cpp` — the palette chip. BSD-3-Clause,
  copyright-holder **Nicola Salmoria**.
* `src/mame/taito/taitoio.cpp` — TC0220IOC (inputs, DIPs, coin
  counters/lockout, watchdog). BSD-3-Clause, copyright-holder **Nicola
  Salmoria**.
* `src/mame/shared/taitosnd.cpp` — TC0140SYT/PC060HA sound communication.
  BSD-3-Clause, copyright-holder **Philip Bennett**.

All of the above are BSD-3-Clause in MAME's own tree.

**[Raine](http://rainemu.swishparty.org.uk/)**, and specifically **Richard
Bush and the Raine team**, are the original source for the PC090OJ sprite
RAM format this core implements. MAME's own `pc090oj.cpp` says so directly
("Information from Raine"), and `asuka.cpp` gives Richard Bush and the Raine
Team its own separate thanks. Credited here on the same terms MAME credits
them.

**The [MiSTer Taito F2 core](https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer)**
was cloned for reference only into `ref/taitof2/` by `tools/fetch_refs.sh`
(gitignored — it is not part of this repository's history, and **no code
from it is copied into this core**). It was read for two things MAME does
not model: the TC0100SCN's real video timing — 424×262 at 26.686/4 MHz,
`ref/taitof2/rtl/video_timing.sv`, the basis for `rtl/video_timing.sv` — and
the chip's layer-priority output encoding, which corroborates the layer
order `docs/hardware.md` §7.3 derives from the driver. There is no existing
Cadash core for MiSTer or openFPGA. Taito F2 shares three of Cadash's five
custom chips — TC0100SCN, TC0110PCR, TC0220IOC — but not PC090OJ, Cadash's
sprite chip; F2's own boards use the later TC0200OBJ instead, so the sprite
renderer here has no MiSTer prior art to draw on.

**Third-party CPU and sound cores — planned, not yet present.** The finished
core will need a 68000, a Z80 and a YM2151. The plan, consistent with this
author's other cores, is to vendor proven third-party implementations under
their own licences rather than write new ones:

* **fx68k** (68000) — Jorge Cwik ([@ijor](https://github.com/ijor)),
  <https://github.com/ijor/fx68k>.
* **T80 / TV80** (Z80) — e.g. Guy Hutchison's
  [tv80](https://github.com/hutch31/tv80), MIT.
* **JT51** (YM2151) — Jose Tejada
  ([@jotego](https://github.com/jotego)), <https://github.com/jotego/jt51>,
  GPL-3.0-or-later.

None of these are in this repository yet — there is no `modules/` directory —
so nothing above is currently compiled into anything. They're listed here so
the project's eventual licensing position is clear ahead of time rather than
discovered later.

## Licence

There is no `LICENSE` file in this repository yet. Once the third-party
cores above are vendored, this project's licence will likely be constrained
by theirs — JT51 in particular is GPL-3.0-or-later, which is what this
author's other JT51-based cores ship under. Until that happens, the licence
for this repository's own original content (`rtl/`, `tools/`, `docs/`) is
to be decided, not GPL-3.0 by default and not public domain.
