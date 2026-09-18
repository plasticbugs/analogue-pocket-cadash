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

| pass | clocks | worst case measured |
|---|---|---|
| bottom background | 41 groups x 8 | 328 |
| top background | 41 groups x 8 | 328 |
| text | 41 groups x 8 | 328 |
| sprite table scan | 256 entries x 1, plus 3 more per hit | 460 |
| sprite blending | 16 per sprite on the line | 1088 |
| **total** | | **2532** |

The sprite numbers come from `tools/probe_sprites.lua` over a 75-second run:
the worst scanline anywhere in it has **68 sprites** on it (frame 859) and the
worst frame puts **145 sprites** on the screen (frame 2597). Both frames are
in the bench's state set.

Graphics fetches overlap the pass they feed: the tile row for group *i+2* is
requested while group *i* is being written, and the row for sprite *i+1* while
sprite *i* is being blended, so a fetch has 16 clocks to complete rather than
the 8 or 16 it would have back to back.

---

## 6. What the core does not reproduce

* **The HD64180 link CPU.** Two-cabinet link play needs two boards and a
  serial cable; MAME cannot do it either. The shared RAM is plain RAM and the
  Communication Mode DIP is fixed at Stand alone.
* **Wide tilemap mode.** Cadash never sets `ctrl[6]` bit 4.
* **Screen flip.** `ctrl[7]` bit 0 and the PC090OJ's own flip bit are
  implemented but unverified: the game never asks for either, even with the
  Flip Screen DIP on.
