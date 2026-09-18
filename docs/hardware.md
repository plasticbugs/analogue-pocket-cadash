# Cadash — Taito "Asuka" hardware

Everything here is taken from MAME 0.288 (`ref/mame/`, fetched verbatim) or
measured from the running game with the Lua probes in `tools/`. Where a fact
was measured, the probe that measured it is named.

Board: Main PCB (JAMMA) `K1100528A`, Taito 1989, MAME set `cadash` (World),
driver `taito/asuka.cpp`. The other twelve `cadash*` sets differ only in
program ROMs (region byte, language) and the coinage DIP table; the graphics,
sound and sub-CPU ROMs are shared.

---

## 1. Chips and clocks

| Part | Role | Clock |
|---|---|---|
| MC68000P12 | main CPU | 32 MHz / 2 = **16 MHz** (verified on PCB) |
| Z80 | sound CPU | 8 MHz / 2 = **4 MHz** (verified on PCB) |
| HD64180RP8 (Z180) | multi-cabinet link only | **8 MHz** |
| YM2151 (OPM) | FM, 8 channels | 8 MHz / 2 = **4 MHz** (verified on PCB) |
| TC0100SCN | two scrolling tilemaps + one RAM-based text layer | video clock |
| PC090OJ | 16x16 sprites, 256 entries | video clock |
| TC0110PCR | 4096-entry palette RAM + RGB DAC | — |
| TC0220IOC | inputs, DIPs, coin lockout/counters, watchdog | — |
| PC060HA | 68000 <-> Z80 communication unit (CIU) | — |

Two crystals are named in the driver: **32 MHz** (68000) and **8 MHz** (Z80 and
OPM). The video crystal is not modelled by MAME. See section 8.

MAME declares `ROT0` — Cadash is a **horizontal** game, unusually for this
era of Taito, and needs no rotation on the Pocket.

---

## 2. ROMs

MAME set `cadash`, region layout as MAME loads it:

| Region | File | Size | CRC32 | Placement |
|---|---|---|---|---|
| `maincpu` | `c21_14.ic11` | 128 KB | `5daf13fb` | offset 0, **even** bytes (high byte of each word) |
| `maincpu` | `c21_16.ic15` | 128 KB | `cbaa2e75` | offset 1, **odd** bytes |
| `maincpu` | `c21_13.ic10` | 128 KB | `6b9e0ee9` | offset 0x40000, even |
| `maincpu` | `c21_17.ic14` | 128 KB | `bf9a578a` | offset 0x40001, odd |
| `tc0100scn` | `c21-02.9` | 512 KB | `205883b9` | `ROM_LOAD16_WORD_SWAP` — tile graphics, 8x8x4 |
| `pc090oj` | `c21-01.1` | 512 KB | `1ff6f39c` | `ROM_LOAD16_WORD_SWAP` — sprite graphics, 16x16x4 |
| `audiocpu` | `c21-08.38` | 64 KB | `dca495a0` | offset 0, banked |
| `subcpu` | `c21-07.57` | 32 KB | `f02292bd` | HD64180 link code — **not used by this core** |
| `plds` | four PAL dumps | 260/324 B | — | not used by emulation |

Total the core must hold: 512 KB program + 512 KB tiles + 512 KB sprites +
64 KB Z80 = **1.6 MB**.

`ROM_LOAD16_WORD_SWAP` means file byte *i* lands at region offset *i xor 1*.
Both graphics regions are decoded as packed 4bpp, most-significant nibble
first, so the region byte at a given offset holds two horizontally adjacent
pixels, left pixel in the high nibble.

* tiles: `gfx_8x8x4_packed_msb`, 32 bytes per tile, row *y* at bytes 4*y*..4*y*+3
* sprites: `gfx_16x16x4_packed_msb`, 128 bytes per tile, row *y* at bytes 8*y*..8*y*+7

---

## 3. 68000 memory map

From `cadash_state::main_map` (`ref/mame/asuka.cpp:638`).

| Range | Width | Contents |
|---|---|---|
| `000000-07FFFF` | 16 | program ROM, 512 KB |
| `080000-080003` | 16 | PC090OJ sprite control (write only) |
| `0C0000-0C0001` | 8 (odd) | PC060HA master port — read is explicitly `nopr` |
| `0C0002-0C0003` | 8 (odd) | PC060HA master comm (r/w) |
| `100000-107FFF` | 16 | main RAM, 32 KB |
| `800000-800FFF` | 16 | link shared RAM — 2 KB of **bytes**, one per word address |
| `900000-90000F` | 8 (odd) | TC0220IOC |
| `A00000-A0000F` | 16 | TC0110PCR |
| `B00000-B03FFF` | 16 | PC090OJ sprite RAM, 8 KB words |
| `C00000-C0FFFF` | 16 | TC0100SCN RAM, 64 KB |
| `C20000-C2000F` | 16 | TC0100SCN control, 8 registers |

The link shared RAM is a 2 KB byte array that the Z180 sees at its own
`8000-87FF`. The 68000 sees **one byte per word address**: a read returns the
byte zero-extended, a write stores the low byte. `tools/probe_regs.lua`
counts about 2.3 writes per frame in attract mode, so the game does touch it
even standing alone; nothing reads back except itself, so plain RAM suffices.

### Interrupts

`cadash_state::interrupt` runs on the screen's vblank and does two things:

1. asserts **IRQ4** immediately,
2. arms a timer for **500 68000 cycles** which then asserts **IRQ5**.

Both are auto-vectored and asserted with `HOLD_LINE`. 500 cycles at 16 MHz is
31.25 us, a little under half a scanline — well inside vblank.

---

## 4. Z80 memory map

From `base_state::z80_map` (`ref/mame/asuka.cpp:692`); Cadash has no MSM5205.

| Range | Contents |
|---|---|
| `0000-3FFF` | ROM, fixed — first 16 KB of `c21-08.38` |
| `4000-7FFF` | ROM, **banked**: one of four 16 KB windows over the whole 64 KB |
| `8000-8FFF` | RAM, 4 KB |
| `9000-9001` | YM2151 (0 = address, 1 = data) |
| `A000` | PC060HA slave port (write) |
| `A001` | PC060HA slave comm (read/write) |

**The bank register is the YM2151 itself.** MAME wires
`ymsnd.port_write_handler().set_membank(m_audiobank).mask(0x03)`, and ymfm
sends `data >> 6` to that handler when the Z80 writes OPM register `0x1B`
(`3rdparty/ymfm/src/ymfm_opm.cpp:488`). Those two bits are the chip's **CT1
and CT2 output pins**, with CT2 the high bit. So:

    bank = { CT2, CT1 }   -- 16 KB window at 4000-7FFF

Any core must take the bank from the sound chip's control outputs, not from a
latch in the memory map.

The YM2151's IRQ pin drives the Z80's `INT`. The PC060HA drives `NMI` when a
command is waiting, and can also hold the Z80 in reset.

---

## 5. TC0220IOC

Byte-wide at `900000-90000F`, odd bytes only (`umask16(0x00ff)`), so register
*n* is at `900000 + 2n + 1`. From `ref/mame/taitoio.cpp`.

| Reg | Read | Write |
|---|---|---|
| 0 | DSWA | watchdog reset |
| 1 | DSWB | — |
| 2 | IN0 — player 1 | — |
| 3 | IN1 — player 2 | (callback, unused here) |
| 4 | last value written | coin counters and lockout, low nibble |
| 7 | IN2 — system | — |

All inputs are **active low**. Bit assignments, confirmed by listing the
ioport fields from a running machine:

| Bit | IN0 / IN1 | IN2 |
|---|---|---|
| 0 | unused | Coin 1 |
| 1 | unused | Coin 2 |
| 2 | Button 2 | Start 2 |
| 3 | Button 1 | Start 1 |
| 4 | Right | Service 1 |
| 5 | Left | Tilt |
| 6 | Down | unused |
| 7 | Up | unused |

### DIP switches

DSWA (`cadash`, World coinage):

| Bit | Function | Default |
|---|---|---|
| 0 | unused | — |
| 1 | Flip Screen | off |
| 2 | Service Mode | off |
| 3 | Demo Sounds | on |
| 4-5 | Coin A | 1C/1C |
| 6-7 | Coin B | 1C/2C |

DSWB:

| Bit | Function | Default |
|---|---|---|
| 0-1 | Difficulty | Medium |
| 2-3 | Starting Time | 7:00 |
| 4-5 | Added Time after round clear | Default |
| 6-7 | **Communication Mode** | `11` = Stand alone |

`11` is the power-on default and the only setting a single cabinet can use.
`10` is Master and `00` is Slave; both need a second cabinet and the Z180
link, which this core does not implement.

---

## 6. TC0110PCR — palette

Four registers at `A00000`, of which two matter:

* write `A00000` — latch palette address, `addr = data & 0xFFF` (shift 0)
* write `A00002` — store 16-bit colour at `addr`
* read `A00002` — read it back

4096 entries. Cadash's colour format is **xBGR444** with the *low* nibble red
(`cadash_state::color_xbgr444`, `ref/mame/asuka.cpp:484`):

    R = bits 3..0,  G = bits 7..4,  B = bits 11..8    (4 bits each, expanded 4->8)

This is the one place Cadash differs from its board-mates, which use xBGR555.

`tools/probe_regs.lua` sees 7723 palette writes over 900 attract-mode frames,
touching indices 0..2191.

---

## 7. Video

### 7.1 TC0100SCN — tilemaps

64 KB of RAM at `C00000`. Standard (non-wide) layout, which is all Cadash
uses:

| Byte range | Contents |
|---|---|
| `0000-3FFF` | BG0 map, 64x64, two words per tile: attribute then code |
| `4000-5FFF` | TEXT map, 64x64, one word per tile |
| `6000-6FFF` | TEXT character generator, 256 chars x 8x8x2bpp, 16 bytes each |
| `8000-BFFF` | BG1 map, 64x64, two words per tile |
| `C000-C3FF` | BG0 row scroll, one word per screen row |
| `C400-C7FF` | BG1 row scroll, one word per screen row |
| `E000-E0FF` | BG1 column scroll, one word per 8-pixel column |

Tile word pairs: word 0 is the attribute (`bit15` flip Y, `bit14` flip X,
`bits7..0` colour), word 1 is the 16-bit tile code. Text words pack both:
`bit15` flip Y, `bit14` flip X, `bits13..8` colour, `bits7..0` character.

The text layer's characters come from RAM at `6000` and are **2 bits per
pixel**, two bitplanes 8 bytes apart within each 16-byte character
(`charlayout` in `ref/mame/tc0100scn.cpp:232`).

Palette index out of every layer is `colour * 16 + pen`, 12 bits, straight
into the TC0110PCR.

Control registers at `C20000`, one word each:

| Reg | Contents |
|---|---|
| 0 | BG0 scroll X |
| 1 | BG1 scroll X |
| 2 | TEXT scroll X |
| 3 | BG0 scroll Y |
| 4 | BG1 scroll Y |
| 5 | TEXT scroll Y |
| 6 | `bit0` BG0 off, `bit1` BG1 off, `bit2` TEXT off, `bit3` swap BG0/BG1 order, `bit4` wide tilemaps, `bit5` unknown |
| 7 | `bit0` flip screen |

All scroll values are **negated** by the chip: the layer moves by `-reg`.

**What Cadash actually writes**, from `tools/probe_regs.lua` over 900 attract
frames:

* `ctrl[6]` is only ever `0x28` or `0x2F`. Bit 4 is never set, so the core
  needs **no wide-tilemap mode**. Bit 3 is always set, so **BG1 is the bottom
  layer** and the draw order is BG1, BG0, TEXT. `0x2F` additionally disables
  all three layers, which the game uses to blank the screen.
* `ctrl[7]` is only ever `0`; the game never flips the screen, even though
  DSWA bit 1 offers it.
* `ctrl[2]` and `ctrl[5]` (text scroll) are `0` apart from one `0x0010`.
* BG0 and BG1 scroll registers move constantly, and both row-scroll tables
  are in use.

Row scroll is indexed in **screen space**: screen row *y* uses word *y* of the
table. Column scroll applies to BG1 only, is indexed by **source** x
(`colscroll[(src_x & 0x3FF) / 8]`), and shifts that 8-pixel column vertically.

Offsets for Cadash are `set_offsets(1, 0)`, which MAME turns into a tilemap
`scrolldx` of `-1 - 16 = -17` and `scrolldy` of `+8`.

### 7.2 PC090OJ — sprites

8 KB of words at `B00000`; only the first 0x800 **bytes** (256 sprites x
4 words) are the active sprite table. The table is **double-buffered**: the
chip copies it at the rising edge of vblank (`eof_callback`), so a frame draws
the table as it stood at the last vblank.

Per sprite, four words:

| Word | Contents |
|---|---|
| 0 | `bit15` flip Y, `bit14` flip X, `bits3..0` colour |
| 1 | Y position, 9 bits |
| 2 | tile code, 13 bits |
| 3 | X position, 9 bits |

Positions are treated as signed: a value above `0x140` has `0x200`
subtracted. Cadash's offsets are `set_offsets(0, 8)`, added after that.

Word `0xDFF` of sprite RAM is a control register; bit 0 clear means the chip
flips every sprite. The game writes `0x0001` once at startup
(`tools/probe_regs.lua`, `oj_ctrl[0] = 0001:1`), so sprites run unflipped.

Sprite control at `080000` (write only):

    bits 5..2   colour bank offset
    bits 1..0   write acknowledge / handshake, toggled every frame

The palette colour becomes `(word0 & 0x0F) | ((ctrl & 0x3C) << 2)`, an 8-bit
value, and the index is `colour * 16 + pen`. Cadash writes `0x0011` and
`0x0013` in alternation and `0x0010`/`0x0000` at startup, so the colour bank
is a constant **`0x40`** in normal play.

### 7.3 Priority

Cadash uses `fixed_colpri_cb`, which sets MAME's sprite priority mask to
`0xF0`. Working through what the three `tilemap_draw` calls put in the
priority bitmap (1 for the bottom layer, 2 for the middle, 4 for text), that
mask means exactly one rule:

> **Sprites draw over both tilemaps, but under the text layer.**

Within the sprite table the *last* sprite drawn wins: MAME walks entries 0 to
255 forwards when a priority callback is set, and every sprite pixel drawn
sets the priority byte to 31, which `0xF0` does not block. So sprite 255 is on
top, not sprite 0, despite the Raine comment in `pc090oj.cpp` saying
otherwise.

Pen 0 is transparent in every layer. The bottom tilemap is drawn opaque, so
its pen 0 shows as palette entry `colour * 16`.

### 7.4 Screen

MAME declares a 320x256 total screen at 60 Hz with a visible window of
`0..319` by `16..255` — **320x240 visible** — and does not model the real dot
clock. The TC0100SCN's own timing, as reverse-engineered for the MiSTer
Taito F2 core (`ref/taitof2/rtl/video_timing.sv`), is a 424 x 262 raster at
26.686 MHz / 4 = 6.6715 MHz, giving 15.735 kHz and 60.06 Hz. That is standard
arcade timing for the chip and is what this core targets; see
`docs/core-design.md` for the clock the core actually uses.

---

## 8. What this core does not reproduce

* **The HD64180 link CPU and its ROM.** Two-cabinet link play needs two
  boards and a serial connection; MAME flags the driver `MACHINE_NODEVICE_LAN`
  and cannot do it either. The shared RAM is implemented as plain RAM, and the
  Communication Mode DIP is forced to `Stand alone`.
* **Wide tilemap mode** (`ctrl[6]` bit 4). Cadash never sets it.
