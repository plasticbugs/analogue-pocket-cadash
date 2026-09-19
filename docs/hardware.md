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

Within the sprite table the **first** sprite wins, exactly as the Raine notes
quoted at the top of `pc090oj.cpp` say. MAME walks entries 0 to 255 forwards,
which looks like the opposite, but `gfx_element::prio_transpen` sets the top
bit of the priority mask itself (`pmask |= 1 << 31`,
`ref/mame/drawgfx.cpp:963`) and every pixel a sprite touches has its priority
byte set to 31, so nothing later can overwrite it.

A pixel is claimed even when the sprite could not be drawn there, so a sprite
hidden under the text layer still hides the sprites behind it. Measured: with
"last wins" the frozen states differ from MAME by about 1900 pixels each; with
"first wins" they are identical.

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

---

## 9. Scroll arithmetic, written out

Both background layers work out to the same pair of expressions, for MAME
bitmap row *y* (16..255) and column *x* (0..319):

    source x = (x + 17 - ctrl_x - rowscroll[y - 8]) & 0x1FF
    source y = (y -  8 - ctrl_y) & 0x1FF

and BG1 then shifts the sampled row by its column-scroll word:

    source y = (source y - colscroll[source x / 8]) & 0x1FF

The text layer is the same with no scroll tables:

    source x = (x + 17 - ctrl[2]) & 0x1FF
    source y = (y -  8 - ctrl[5]) & 0x1FF

The `17` and the `8` are MAME's `scrolldx`/`scrolldy` for
`set_offsets(1, 0)`: `-1 - 16` and `+8`.

Every one of those subtractions is negated twice on the way through MAME —
once in `restore_scroll`, which stores `-ctrl[n]`, and once in
`effective_rowscroll`, which returns `m_dx - m_rowscroll[i]`
(`ref/mame/tilemap.cpp:35`). **Getting the sign wrong is invisible whenever
the scroll register is a multiple of 512**, which is exactly what the first
state tested happened to be, and what made the error survive into three later
states before a frame with an odd scroll value exposed it.

The row-scroll word used for bitmap row *y* is the one the game wrote for
screen row *y - 8*: `tilemap_update` indexes the table by `j + m_bgscrolly`
and the draw indexes it by `y - scrolly`, and the two scroll terms cancel.

---

## 10. Reading MAME's output correctly

The reference renderer is checked against `screen:pixels()`, and three
properties of MAME's own pipeline have to be undone first. All three were
measured, not assumed, with the controlled experiments in this repository's
history (write a known value at frame K, watch which frame it appears in).

1. **The picture lags the state by one frame.** `video_manager::frame_update`
   renders the screen and *then* calls the Lua frame notifier, and
   `screen_device::update_quads` flips `m_curbitmap` after publishing the
   texture (`ref/mame/screen.cpp:1792`). So `screen:pixels()` read in callback
   *N* is the frame drawn from the state as it stood in callback *N-1*.

2. **The sprite table lags by a further frame.** The PC090OJ copies its table
   at the rising edge of vblank, which `screen_device::vblank_begin` raises
   *after* `frame_update` has already drawn the frame. So the frame drawn in
   callback *N-1* used the table as it stood in callback *N-2*.

3. **The palette does not lag at all.** MAME's screens are 16-bit indexed: the
   bitmap holds palette indices and the lookup happens when the picture is
   read out. A frame's colours are therefore whatever the palette holds a
   frame later. This is invisible until the game fades the screen.

`tools/dump_state.lua` writes a state file with all three undone, so
`tools/render_model.py` can diff it against MAME with no offsets of its own.

Two smaller traps in MAME's Lua, both of which cost time here:

* **Callbacks must be held in globals.** The bindings keep only a weak hold on
  them, and a chunk's locals become collectable as soon as the autoboot script
  returns, so a callback stored in a local stops firing a few hundred frames
  in, silently and with no error.
* **`install_read_tap` on a range served by an installed read handler** kills
  the notifier chain outright: nothing errors, the machine runs on, and no
  callback ever fires again. Shadow write-only registers with write taps
  instead, and read state back through the chip's own ports.

---

## 11. The cabinet link

Not implemented, and MAME does not emulate it either ("needs two MAME
instances"), so everything here is read out of the two programs: the link
CPU's ROM `c21-07.57`, disassembled in full, and the 68000's side of the
shared RAM. There is no oracle for this section. It is a reading, checked for
internal consistency -- every branch target in the listing below lands on an
instruction boundary -- and nothing more.

### 11.1 The link CPU's program is 234 bytes

The ROM is 32 KB and all but `0000-00E9` is `FF`. The only HD64180-specific
instructions in it are `IN0` and `OUT0`; there is no `MLT`, no MMU setup, no
DMA, no timer and no interrupt handler. The internal registers it touches are
the first serial channel's -- `CNTLA0` (00), `CNTLB0` (02), `STAT0` (04),
`TDR0` (06), `RDR0` (08) -- plus `DCNTL` and `RCR` once each at start-up.

```
0000  DI
0001  LD   SP,8800h            ; the stack is the top of the shared RAM
0004  LD   A,10h : OUT0 (CNTLB0),A    ; odd parity, clock/10/16/1
0009  ...                      ; short delay loop
0012  LD   A,36h : OUT0 (CNTLA0),A    ; TE, RTS high, 8 bits + parity, 1 stop
0017  LD   A,00h : OUT0 (STAT0),A     ; no serial interrupts
001C  LD   A,40h : OUT0 (DCNTL),A     ; one memory wait state
0021  LD   A,00h : OUT0 (RCR),A       ; DRAM refresh off
0026  IN0  A,(RDR0)            ; flush
0029  XOR  A : LD (8001h),A    ; error flag = 0
002D  EI                       ; nothing is enabled and there is no handler
002E  LD   DE,0                ; D = packets sent, E = packets received
0031  LD   A,(8000h) : CP 'M'
0036  JR   NZ,0074             ; anything but 'M' is a slave: start by listening

      ; ---- send one packet
0038  LD   A,'T' : LD (8002h),A
003D  LD   A,(8080h) : OR A : JR Z,003D      ; wait for the 68000 to post one
0043  CP   40h : JR NC,00C2                  ; 64 bytes or more is an error
0047  LD   C,A : LD HL,8080h                 ; C = length, count byte included
004B  LD   A,26h : OUT0 (CNTLA0),A           ; RTS low: "I have a byte"
0050  IN0  A,(CNTLB0) : AND 20h : JR NZ,0050 ; wait for CTS low: "go on"
0057  LD   B,(HL) : CALL 00C9                ; transmit it
005B  IN0  A,(CNTLB0) : AND 20h : JR Z,005B  ; wait for CTS high: "got it"
0062  LD   A,36h : OUT0 (CNTLA0),A           ; RTS high
0067  INC  HL : DEC C : JR NZ,004B
006B  XOR  A : LD (8080h),A                  ; sent: the 68000 may post another
006F  INC  D : LD A,D : LD (8005h),A

      ; ---- receive one packet
0074  LD   A,'R' : LD (8002h),A
0079  LD   HL,8100h
007C  LD   A,(8100h) : OR A : JR NZ,007C     ; wait for the 68000 to take the last
0082  IN0  A,(CNTLB0) : AND 20h : JR NZ,0082 ; wait for CTS low: "I have a byte"
0089  LD   A,46h : OUT0 (CNTLA0),A           ; RE, RTS low: "go on"
008E  CALL 00D8 : LD (HL),A : LD C,A         ; the first byte is the length
0093  JR   00A5
0095  IN0  A,(CNTLB0) : AND 20h : JR NZ,0095
009C  LD   A,46h : OUT0 (CNTLA0),A
00A1  CALL 00D8 : LD (HL),A
00A5  LD   A,56h : OUT0 (CNTLA0),A           ; RE, RTS high: "got it"
00AA  INC  HL : DEC C : JR Z,00B7
00AE  IN0  A,(CNTLB0) : AND 20h : JR Z,00AE  ; wait for the sender's RTS high
00B5  JR   0095
00B7  INC  E : LD A,E : LD (8006h),A
00BC  LD   A,(C000h)                         ; a strobe; the value is discarded
00BF  JP   0038                              ; and now it is this side's turn

00C2  LD   A,'E' : LD (8001h),A : JR 00C2    ; any error: flag it and stop dead

00C9  IN0  A,(STAT0) : LD (8003h),A : AND 02h : JR Z,00C9   ; wait for TDRE
00D3  LD   A,B : OUT0 (TDR0),A : RET
00D8  IN0  A,(STAT0) : LD (8004h),A : AND F0h : JR Z,00D8   ; wait for RDRF or an error
00E2  AND  70h : JR NZ,00C2                                  ; overrun, parity, framing
00E6  IN0  A,(RDR0) : RET
```

### 11.2 What that means

* **Both boards run the same loop and differ only in where they enter it.**
  The master sends first; the slave listens first. After that each side
  alternates send, receive, send. The two are never transmitting at once:
  it is strict ping-pong, one packet each way per exchange.
* **The line is asynchronous serial with a hardware handshake on every byte.**
  8 data bits, odd parity, 1 stop. The rate is the CPU clock divided by 160:
  25,000 baud if the 8 MHz in MAME's driver is the crystal (the HD64180 halves
  it), 50,000 if it is the clock itself. Four signals cross between the
  boards, plus ground: `TXA0` to the other side's `RXA0`, and `RTS0` to the
  other side's `CTS0`, in both directions. For each byte the sender drops
  RTS, waits for the receiver to drop its own, transmits, waits for the
  receiver to raise RTS again, and raises its own.
* **The shared RAM is the whole interface to the 68000.** The Z180's
  `8000-87FF` is the 68000's `800000-800FFF`, one byte per word address, so
  Z180 address `8000h + n` is 68000 address `800000h + 2n`.

| Z180 | 68000 | who writes it | meaning |
|---|---|---|---|
| `8000` | `800000` | 68000, at boot | `'M'` master, `'S'` otherwise |
| `8001` | `800002` | Z180 | `'E'` after any error; the Z180 has stopped |
| `8002` | `800004` | Z180 | `'T'` while sending, `'R'` while receiving |
| `8003`, `8004` | `800006`, `800008` | Z180 | last `STAT0` seen while sending / receiving |
| `8005`, `8006` | `80000A`, `80000C` | Z180 | packets sent / received, mod 256 |
| `8080-80BF` | `800100-` | 68000, then Z180 clears `8080` | outgoing packet; writing the length byte last launches it |
| `8100-813F` | `800200-` | Z180, then 68000 clears `8100` | incoming packet; the Z180 will not receive another until the length byte is zero |
| `87FE-87FF` | `800FFC-` | Z180 | its stack: two bytes, the one `CALL` deep it ever goes |

MAME's comment calls `8080` "slave data" and `8100` "master data". They are
the transmit and receive buffers, the same way round on both boards.

### 11.3 The 68000's side

`00B0C` clears all of `800000-800FFF`, then reads DSWB: bit 7 set writes
`'M'` to `800000`, clear writes `'S'`.

`0490E` builds a packet at `800100`: the length, the two player-input words
(`900004` and `900006`, this frame's or last frame's depending on the sign of
the link-mode byte at `$3404(A5)`), up to 63 queued event bytes from
`$3420(A5)`, and a checksum that makes the bytes sum to zero. The length is
written last. If the previous packet is still waiting and the board is linked,
the 68000 **spins until the Z180 clears the length byte**, so the link's speed
is part of the game's timing. This routine runs in stand-alone mode too.

`048A0` takes a packet from `800200`: copies it to `$351A(A5)`, checks the
sum, clears the length byte to release the Z180, and sets `$3405(A5)`. A bad
sum while linked prints `COMMUNICATION CHECKSUM ERROR`, writes 0 to `080000`
and halts with interrupts masked.

### 11.4 What is still not known

* **What holds the Z180 back at power-up.** It reads `8000` within a few
  milliseconds of reset, and the 68000 does not write `'M'` there until after
  its RAM test. MAME's author suspected a missing halt line. One candidate is
  in plain sight: the 68000's first instruction after masking interrupts is to
  write 0 to `080000`; it writes `10h` or `13h` there only once `'M'`/`'S'` is
  in place; and its fatal link-error path writes 0 there again before halting.
  MAME maps `080000` to the sprite chip's control register and knows no
  meaning for bit 4 beyond the colour bank. Bit 4 releasing the Z180's reset
  would fit all three writes. So would coincidence. An implementation does not
  need to settle it: holding the link CPU until `800000` has been written is
  correct under either reading.
* **The read of `C000`** after every received packet. Nothing is mapped there
  and the value is thrown away, so it is a strobe -- a watchdog, a lamp, an
  interrupt nobody takes. The 68000 polls the length bytes and does not need
  one.
* **`EI` with no handler.** `STAT0` is written 0, so the serial channel raises
  nothing, and the NMI vector at `0066` is the middle of an instruction. If
  `INT0` is wired to anything the program would not survive it; presumably it
  is not.
* **`DCD0`** must be low or the HD64180's receiver never sets `RDRF`.
  Presumably strapped.
* **What two linked cabinets actually show.** Four players, by the input words
  in the packet; whether the screens follow each other is a question for
  someone with two boards.

### 11.5 On the Pocket

The link port gives the core four pins with direction control and imposes no
protocol (`port_tran_si`, `_so`, `_sck`, `_sd` in `core_top.sv`, tri-stated
today). The board wants four directed signals and a Game Boy cable crosses
only SO to SI each way, with SCK shared, so the wires cannot be mapped one for
one -- while a side waits in `36h` for its peer to start sending, both believe
they are the transmitter, and a shared handshake wire would be driven from
both ends.

They do not need to be. Both ends of the cable are this core, so the
handshake can travel in band: each side's SO carries short frames that are
either a data byte or a change in its RTS level, in the order they happened,
at a rate far above 25,000 baud so the added delay is a few percent of a bit.
That needs SO, SI and ground -- a Game Boy / Game Boy Color cable -- and no
direction switching at all.

A Game Boy Advance cable is a different animal: SO reaches the other end's SI
in one direction only, and SD is the wire both ends share. Because the
protocol is strict ping-pong it could still be carried, by terminating the
per-byte handshake locally at each end and shipping whole packets alternately
over SD. That is a second, harder design, and the cable's wiring should be
confirmed with a meter first.

The link CPU itself can be done two ways. **Run the real ROM**: TV80 is a Z80
and treats `ED 38`/`ED 39` as no-ops, so it would need `IN0`/`OUT0` added --
a change to a vendored core that is otherwise kept exactly as upstream -- plus
a one-channel ASCI, and `c21-07.57` added to the ROM image. **Or replace it**
with a state machine that honours the shared-RAM contract in section 11.2,
which is all the 68000 can see. The program is small enough that the second
is a fair reading of the first, and it can be checked: a twenty-opcode
interpreter running the real 234 bytes makes an executable reference for the
state machine, and two copies of the whole machine wired back to back in
Verilator make the system test. Neither is MAME, and neither is two real
boards.
