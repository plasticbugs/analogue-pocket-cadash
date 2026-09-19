# Mapping the board onto the Analogue Pocket

`docs/hardware.md` says what the board does. This says how the core does it,
and why each memory ended up where it did.

---

## 1. What is borrowed, and from where

There is no Cadash core for MiSTer. There is
[`Arcade-TaitoF2_MiSTer`](https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer),
and Taito F2 shares three of Cadash's five custom chips: **TC0100SCN**
(tilemaps), **TC0110PCR** (palette) and **TC0220IOC** (inputs). Its RTL is
cloned into `ref/taitof2/` by `tools/fetch_refs.sh` and was read for two
things this core takes from it:

* **The TC0100SCN's real video timing** — 424 x 262 at 26.686 MHz / 4, which
  MAME does not model at all (`ref/taitof2/rtl/video_timing.sv`).
* **The chip's layer-priority output encoding**, which confirms the layer
  order the driver implies (`ref/taitof2/rtl/tc0100scn.sv`).

What it does *not* provide is **PC090OJ**, Cadash's sprite chip; F2 uses the
much later TC0200OBJ instead. It is also built around MiSTer's framework,
clocking and SDRAM, none of which transfer to the Pocket.

So the renderers here are written against `tools/render_model.py`, which is
pixel-identical to MAME across ten states including the heaviest sprite load
in the game. That is a tighter specification than another core's source, and
it comes with a bench that can prove the RTL meets it.

---

## 2. Clocks

One system clock, **96 MHz**, from the core PLL, and every other rate is a
clock enable derived from it, so the only clock-domain crossings in the core
are the Pocket's own.

96 MHz divides exactly into every clock the board has:

| | board | core | divider |
|---|---|---|---|
| 68000 | 16 MHz | 16 MHz | 96 / 6 |
| Z80 | 4 MHz | 4 MHz | 96 / 24 |
| YM2151 | 4 MHz | 4 MHz | 96 / 24 |

The video is the one thing that cannot be exact. The chip's dot clock is
26.686 / 4 = 6.6715 MHz, which shares no useful ratio with 96 MHz, and a
second PLL for the video would buy 1% of dot-clock accuracy at the price of a
clock-domain crossing on every pixel. So the core runs the video 2.8% fast and
takes the horizontal total back the other way:

| | board | core |
|---|---|---|
| dot clock | 6.6715 MHz | 6.857 MHz (96/14) |
| htotal | 424 | 436 |
| vtotal | 262 | 262 |
| line rate | 15.735 kHz | 15.727 kHz |
| frame rate | 60.06 Hz | 60.03 Hz |

Both rates land within 0.06% of the board's. What the extra dot clocks buy is
a slightly longer horizontal blanking, which nothing observes.

The visible window is **320 x 240**, the same as MAME's, and Cadash is a
horizontal game (`ROT0`), so the Pocket displays it without rotation.

---

## 3. Memories

The romset is 1.6 MB, which is far more than the Cyclone V's ~385 KB of block
RAM, but everything the core *writes* is small:

### Block RAM — all of the RAM

| | size | why here |
|---|---|---|
| TC0100SCN VRAM, 32768 x 16 | 64 KB | read six times per 8-pixel group by three layer renderers |
| PC090OJ sprite RAM, 8192 x 16 | 16 KB | CPU side |
| PC090OJ buffered table, 1024 x 16 | 2 KB | what the sprite renderer walks |
| 68000 main RAM, 16384 x 16 | 32 KB | |
| TC0110PCR palette, 4096 x 16 | 8 KB | read once per displayed pixel |
| Z80 RAM, 4096 x 8 | 4 KB | |
| link shared RAM, 2048 x 8 | 2 KB | |
| two line buffers, 320 x 14 | 1 KB | |
| **total** | **129 KB** | |

That is about a third of the device, so the Pocket's 256 KB SRAM is left
unused and every RAM access in the core is single-cycle and deterministic.
Deterministic access is worth more here than the saved blocks: the line
renderer's budget (section 5) is tight enough that a variable-latency VRAM
would have to be designed around.

### SDRAM — the whole ROM image

All 1.6 MB, exactly as `cadash.mra` builds it:

| offset | size | contents |
|---|---|---|
| `0x000000` | 512 KB | 68000 program |
| `0x080000` | 64 KB | Z80 program |
| `0x090000` | 512 KB | tile graphics, one 8-pixel row per 32-bit word |
| `0x110000` | 512 KB | sprite graphics, one 16-pixel row per two 32-bit words |

Both CPUs read their program through a small direct-mapped cache. The ROM is
read-only, so an entry can never go stale, which is the cheapest safety there
is. The renderers read graphics in short bursts, two SDRAM words for a tile
row and four for a sprite row.

---

## 4. The video pipeline

Line *N+1* is rendered into one line buffer while line *N* is read out of the
other. A line buffer entry is 14 bits: a 12-bit palette index, a **text** bit
and a **claimed** bit.

The renderer makes four passes, in the order `tools/render_model.py` proves is
right:

1. **bottom background** — `ctrl[6]` bit 3 picks which of BG0/BG1 it is;
   written opaquely, so no clear pass is needed
2. **top background** — written where the pen is not 0
3. **text layer** — written where the pen is not 0, setting the *text* bit
4. **sprites** — walked in table order; a pixel with a non-zero pen sets the
   *claimed* bit and is written only if *claimed* was clear and *text* is clear

Pass 4 is the whole of Cadash's sprite priority. A sprite claims a pixel even
when the text layer stops it drawing, which is what makes the rule "the first
sprite in the table wins" rather than "the first visible one wins".

---

## 5. The line budget

A line is 436 dot clocks, and at 96 MHz that is **6104 system clocks**.

| pass | what it costs | measured worst |
|---|---|---|
| three tilemap passes | 41 groups each, the larger of 8 pixels and one fetch | 1891 |
| sprites | 2 clocks per entry missed, the larger of 16 pixels and one fetch per hit | 1656 |
| **worst line seen** | | **3840 of 6104** |

The sprite numbers come from `tools/probe_sprites.lua` over a 75-second
attract-mode run: the worst scanline anywhere in it has **68 sprites** on it
(frame 859) and the worst frame puts **145 sprites** on the screen (frame
2597). Both frames are in the bench's state set, and the figures above are
frame 859 at a modelled graphics-ROM latency of 12 clocks.

Fetching and drawing run side by side in both renderers, each with a
one-entry slot between them, so a group or a sprite costs the larger of its
pixels and its fetch rather than the sum. That is what buys the headroom:

| graphics ROM latency | worst line |
|---|---|
| 6 clocks | 2932 |
| 12 clocks | 3840 |
| 20 clocks | 4739 |
| 30 clocks | over budget |

So the renderer tolerates about 25 clocks of latency per graphics read before
a line stops fitting, which is the number the SDRAM controller has to beat
under contention with both CPUs.

---

## 6. What the core does not reproduce

* **The HD64180 link CPU.** Two-cabinet link play needs two boards and a
  serial cable; MAME cannot do it either. The shared RAM is plain RAM and the
  Communication Mode DIP is fixed at Stand alone.
* **Wide tilemap mode.** Cadash never sets `ctrl[6]` bit 4.
* **Screen flip.** `ctrl[7]` bit 0 and the PC090OJ's own flip bit are
  implemented but unverified: the game never asks for either, even with the
  Flip Screen DIP on.


---

## 7. Timing

The core closes at 96 MHz with **+0.459 ns** of setup slack at the Slow 85 °C
corner and +0.404 at the cold one; the worst number anywhere in the report,
across every corner and every check, is +0.101 ns.  It fits in 8,542 of 18,480
ALMs and 246 of 308 RAM blocks.

Getting there took two wrong answers first, which are worth recording because
both were plausible and both were measured rather than argued away.

**The path was not where it looked.**  The tilemap RAM needs three ports -- a
read for the CPU, a read for the renderer and a write -- and an M10K has two,
so Quartus builds all 64 KB twice and sends every write to both copies.  That
duplicated write is the obvious suspect, and it is wrong: the net is not even
in the fitter's high fan-out table.  `report_timing -detail full_path` names
the real one:

```
ram_block1a1|portbdataout[0]   VRAM read data out          1.181 ns
  -> vram_rtl_0|mux5           the output mux over 64 M10Ks 0.562
  -> u_tm|Add0~1 .. Add0~13    a subtract                   1.370
  -> u_tm|Selector104~4                                     0.600
  -> ram_block1a39|portbaddr[8] back into the VRAM address  2.095
```

9.303 ns of data delay in a 10.416 ns period: the renderer was reading a word
out of VRAM, subtracting it, and using the result as the next VRAM address
inside one clock.  Two places did it -- `G_COLSC` forming BG1's attribute
address from the column-scroll word as it arrived, and `G_ATTR` forming the
text character address from the attribute word -- and both were deliberate,
saving a clock per group.  `G_COLSC_W` and `G_ATTR_W` let each value land in a
register first.  The cost is one clock per group, which took the worst line
from 3547 to 3589 of 6104.

**Two things that sounded right and measured worse.**  Registering the RAM's
write signals, to give the fitter a fabric register to duplicate near each
half, went from -0.090 to -0.466: it moved the fan-out rather than reducing
it.  Switching the fitter from area-first to speed-first, with register
duplication on, went to -0.394 and added 1,117 registers -- the register that
needed duplicating lives inside an M10K, where the fitter cannot reach it.

**And one that worked, and was still dropped.**  Marking the array
`(* ramstyle = "no_rw_check" *)` collapses the two copies into one true
dual-port array, because the guarantee Quartus is otherwise forced to keep --
that a renderer read returns the *old* word when the CPU writes that address on
that clock -- is not one an M10K can make in true dual-port mode.  It works,
and it is a large win on paper: 246 RAM blocks to 182, 524,288 fewer memory
bits.  It is not in the tree, for two reasons.  It moved the fitter's placement
enough to cost 1.23 ns of clock skew on the SDRAM read capture path, which put
that path 0.3 ns under water; and block RAM was never the scarce resource here
while timing margin is.  Dropping it also means nothing ships that rests on an
argument Verilator cannot check, since Verilator models old-data reads
unconditionally and would pass either way.

The SDRAM capture path is worth a note of its own, because it is the one that
is closest to the edge and the least under the core's control.  It is
constrained honestly -- `set_input_delay -max 7.0` with a `-setup 2` multicycle
gives a 14.322 ns relationship -- the capture registers are packed into the I/O
cells, and the 2.844 ns of data delay is identical to Gaiapolis's on the same
pins.  All that separates a passing build from a failing one is how the fitter
places the clock control blocks: Gaiapolis gets -3.379 ns of skew on that path
and a build of this core with the RAM attribute got -4.610.  There is a
principled lever if it ever bites -- reducing the PLL's 225 degree phase shift
widens the read relationship, and the write side is constrained by
`set_output_delay` so the analyser would check the trade rather than the
author having to guess it -- but it changes a hardware-facing number inherited
from a core proven on the panel, and it has not been needed.
