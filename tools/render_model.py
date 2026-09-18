#!/usr/bin/env python3
"""Reference renderer for Cadash's video hardware, and a diff against MAME.

This is the executable spec the RTL is written against.  It takes a state
dumped by tools/dump_state.lua and the ROM image cadash.mra builds, and
produces the frame MAME produces -- the same 320x240 pixels, not merely a
similar picture.  Every rule here is traced to a line of MAME 0.288 in
ref/mame/, because the point of the exercise is to own a readable statement of
the semantics rather than re-derive them from C++ while writing Verilog.

Usage:
    render_model.py <state.bin> <image.rom> [--png out.png] [--idx out.bin]
                    [--quiet]

--idx writes the 320x240 palette indices as little-endian u16, which is what
the RTL bench in sim/ diffs against: comparing indices rather than colours
keeps the video test independent of the palette conversion.
"""
import sys, struct
from array import array

SCREEN_W, SCREEN_H = 320, 240
# MAME's screen is 320x256 and the visible window is y 16..255, so a dumped
# row r is bitmap row r + VIS_TOP.  Every scroll calculation below is in
# bitmap coordinates, which is what the MAME code does.
VIS_TOP = 16

# Where each region sits in the image cadash.mra builds.
PROG_BASE = 0x000000
SND_BASE  = 0x080000
SCN_BASE  = 0x090000     # 8x8x4 packed, 32 bytes per tile
OBJ_BASE  = 0x110000     # 16x16x4 packed, 128 bytes per tile
SCN_TILES = 0x80000 // 32
OBJ_TILES = 0x80000 // 128

# TC0100SCN RAM layout, in 16-bit words (ref/mame/tc0100scn.cpp:33).
BG0_W      = 0x0000 // 2
TX_W       = 0x4000 // 2
TXGFX_W    = 0x6000 // 2
BG1_W      = 0x8000 // 2
BG0SCROLL_W = 0xc000 // 2
BG1SCROLL_W = 0xc400 // 2
COLSCROLL_W = 0xe000 // 2


class State:
    """One frame of video state, as tools/dump_state.lua writes it."""

    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:4] != b'CDST':
            raise ValueError(f'{path}: not a Cadash state dump')
        ver, self.frame = struct.unpack_from('<II', d, 4)
        if ver != 2:
            raise ValueError(f'{path}: version {ver}, expected 2')
        o = 12
        self.ctrl = list(struct.unpack_from('<8H', d, o));          o += 16
        self.scn  = list(struct.unpack_from('<32768H', d, o));      o += 65536
        self.spr  = list(struct.unpack_from('<1024H', d, o));       o += 2048
        self.spr_ctrl, self.oj_ctrl = struct.unpack_from('<2H', d, o); o += 4
        self.pal  = list(struct.unpack_from('<4096H', d, o));       o += 8192
        self.pixels = d[o:o + SCREEN_W * SCREEN_H * 4]
        if len(self.pixels) != SCREEN_W * SCREEN_H * 4:
            raise ValueError(f'{path}: short pixel block')


def rgb_of(colour):
    """TC0110PCR entry -> (r, g, b).

    Cadash alone among its board-mates uses xBGR444 with red in the low
    nibble (cadash_state::color_xbgr444, ref/mame/asuka.cpp:484).
    """
    r = (colour >> 0) & 0xf
    g = (colour >> 4) & 0xf
    b = (colour >> 8) & 0xf
    return (r * 0x11, g * 0x11, b * 0x11)


def bg_pixmap(st, base_w, rom):
    """Render one 64x64 background tilemap to a 512x512 array of palette indices.

    Two words per tile: word 0 is the attribute (bit15 flip Y, bit14 flip X,
    bits 7..0 colour), word 1 is the tile code
    (tc0100scn_base_device::get_bg_tile_info).  Tile rows are memoised because
    a frame uses only a few hundred distinct tiles out of 16384.
    """
    px = array('H', bytes(512 * 512 * 2))
    cache = {}
    scn = st.scn
    for ty in range(64):
        for tx in range(64):
            i = base_w + (ty * 64 + tx) * 2
            attr = scn[i]
            key = (scn[i + 1] % SCN_TILES, attr & 0xc0ff)
            rows = cache.get(key)
            if rows is None:
                code, a = key
                colour, flipx, flipy = a & 0xff, (a >> 14) & 1, (a >> 15) & 1
                src = SCN_BASE + code * 32
                base = colour * 16
                rows = []
                for y in range(8):
                    sy = 7 - y if flipy else y
                    b = rom[src + sy * 4: src + sy * 4 + 4]
                    pens = [(b[x >> 1] >> 4) if (x & 1) == 0 else (b[x >> 1] & 0xf)
                            for x in range(8)]
                    if flipx:
                        pens.reverse()
                    rows.append(array('H', [base + p for p in pens]))
                cache[key] = rows
            o = (ty * 8) * 512 + tx * 8
            for y in range(8):
                px[o:o + 8] = rows[y]
                o += 512
    return px


def tx_pixmap(st):
    """Render the 64x64 text tilemap to a 512x512 array of palette indices.

    Characters live in RAM at 0x6000 as 2bpp, two bitplanes 8 bytes apart
    within each 16-byte character (charlayout, ref/mame/tc0100scn.cpp:232).
    MAME decodes that data through a byte-swapping xormask on a little-endian
    host, so plane 0 is the high byte of each RAM word and plane 1 the low.
    """
    px = array('H', bytes(512 * 512 * 2))
    cache = {}
    scn = st.scn
    for ty in range(64):
        for tx in range(64):
            attr = scn[TX_W + ty * 64 + tx]
            rows = cache.get(attr)
            if rows is None:
                ch = attr & 0xff
                colour = (attr >> 8) & 0x3f
                flipx, flipy = (attr >> 14) & 1, (attr >> 15) & 1
                base = colour * 16
                rows = []
                for y in range(8):
                    sy = 7 - y if flipy else y
                    w = scn[TXGFX_W + ch * 8 + sy]
                    p0, p1 = w >> 8, w & 0xff
                    pens = [(((p0 >> (7 - x)) & 1) << 1) | ((p1 >> (7 - x)) & 1)
                            for x in range(8)]
                    if flipx:
                        pens.reverse()
                    rows.append(array('H', [base + p for p in pens]))
                cache[attr] = rows
            o = (ty * 8) * 512 + tx * 8
            for y in range(8):
                px[o:o + 8] = rows[y]
                o += 512
    return px


def render(st, rom):
    """-> (indices, drawn, sprite_blocked) for the 320x240 visible window.

    `indices` is the palette index per pixel, `drawn` says whether anything
    opaque was put there, and `sprite_blocked` marks pixels the text layer
    claimed, which is the whole of Cadash's sprite priority rule.
    """
    ctrl = st.ctrl
    bg0_off = ctrl[6] & 0x01
    bg1_off = ctrl[6] & 0x02
    tx_off  = ctrl[6] & 0x04
    # ctrl[6] bit 3 picks which background is underneath; Cadash always sets
    # it, so BG1 is the bottom layer (base_state::screen_update).
    bottom = 1 if (ctrl[6] & 0x08) else 0
    order = [bottom, bottom ^ 1, 2]

    bg = [None, None]
    bg[0] = bg_pixmap(st, BG0_W, rom) if not bg0_off else None
    bg[1] = bg_pixmap(st, BG1_W, rom) if not bg1_off else None
    tx = tx_pixmap(st) if not tx_off else None

    out = array('H', bytes(SCREEN_W * SCREEN_H * 2))
    drawn = bytearray(SCREEN_W * SCREEN_H)
    blocked = bytearray(SCREEN_W * SCREEN_H)

    # MAME's tilemap scrolldx/scrolldy for set_offsets(1, 0): -1 - 16 and 8.
    DX, DY = -17, 8

    for pos, layer in enumerate(order):
        opaque = (pos == 0)
        if layer == 2:
            if tx is None:
                continue
            # Single scroll value for the whole layer; effective scroll is
            # (m_dx - rowscroll) because MAME subtracts (tilemap.cpp:35) and
            # the chip's registers are already negated by restore_scroll().
            sx0 = (DX + ctrl[2]) & 0x1ff
            sy0 = (DY + ctrl[5]) & 0x1ff
            for r in range(SCREEN_H):
                y = r + VIS_TOP
                srow = ((y - sy0) & 0x1ff) * 512
                o = r * SCREEN_W
                for x in range(SCREEN_W):
                    p = tx[srow + ((x - sx0) & 0x1ff)]
                    if p & 0xf:
                        out[o + x] = p
                        drawn[o + x] = 1
                        blocked[o + x] = 1
            continue

        pm = bg[layer]
        if pm is None:
            continue
        if layer == 0:
            scroll_x, scroll_y, rows_w = ctrl[0], ctrl[3], BG0SCROLL_W
        else:
            scroll_x, scroll_y, rows_w = ctrl[1], ctrl[4], BG1SCROLL_W
        # Both layers end up with the same form:
        #
        #     source x = x + 17 - ctrl_x - rowscroll[y - 8]
        #     source y = y -  8 - ctrl_y
        #
        # The row-scroll word for bitmap row y is the one written for screen
        # row y - 8, because tilemap_update indexes by (j + m_bgscrolly) and
        # the draw indexes by (y - scrolly), and the two scrolls cancel.
        #
        # Both subtractions are negated twice: the chip's registers are
        # negated into m_bgscrollx (tc0100scn.cpp restore_scroll) and MAME's
        # effective_rowscroll subtracts again (tilemap.cpp:35).  Getting this
        # sign wrong is invisible whenever the scroll register happens to be a
        # multiple of 512, which is how it survived the first frames tested.
        colscroll = (layer == 1)
        for r in range(SCREEN_H):
            y = r + VIS_TOP
            rs = st.scn[rows_w + ((y - DY) & 0x1ff)]
            sx = (-DX - scroll_x - rs) & 0x1ff
            sy = (y - DY - scroll_y) & 0x1ff
            o = r * SCREEN_W
            for x in range(SCREEN_W):
                src_x = (x + sx) & 0x1ff
                if colscroll:
                    off = st.scn[COLSCROLL_W + ((src_x & 0x3ff) >> 3)]
                    src_y = (sy - off) & 0x1ff
                else:
                    src_y = sy
                p = pm[src_y * 512 + src_x]
                if opaque or (p & 0xf):
                    out[o + x] = p
                    drawn[o + x] = 1

    draw_sprites(st, rom, out, drawn, blocked)
    return out, drawn


def draw_sprites(st, rom, out, drawn, blocked):
    """PC090OJ, 256 entries of four words (ref/mame/pc090oj.cpp:167).

    **The first sprite in the table wins.**  MAME walks the table forwards,
    but `gfx_element::prio_transpen` sets the top bit of the priority mask
    itself (`pmask |= 1 << 31`, ref/mame/drawgfx.cpp:963) and every pixel a
    sprite touches has its priority byte set to 31, so no later sprite can
    ever overwrite it.  The Raine notes quoted at the top of pc090oj.cpp say
    the same thing; the forward walk makes it look like the opposite.

    A pixel is claimed even when the sprite could not draw it, which is what
    makes the rule "first sprite wins" rather than "first visible sprite
    wins": a sprite hidden under the text layer still blocks the ones behind
    it.  Cadash's only other priority rule comes from `fixed_colpri_cb`,
    pri_mask 0xF0, which blocks a sprite exactly where the text layer drew.

    Cadash's sprite RAM is double-buffered, so what is drawn is the table as
    it stood at the last vblank.
    """
    colbank = (st.spr_ctrl & 0x3c) << 2
    flip_all = not (st.oj_ctrl & 1)
    claimed = bytearray(SCREEN_W * SCREEN_H)
    X_OFF, Y_OFF = 0, 8
    for offs in range(0, 0x400, 4):
        data = st.spr[offs]
        flipy = (data >> 15) & 1
        flipx = (data >> 14) & 1
        colour = (data & 0x000f) | colbank
        code = (st.spr[offs + 2] & 0x1fff) % OBJ_TILES
        x = st.spr[offs + 3] & 0x1ff
        y = st.spr[offs + 1] & 0x1ff
        if x > 0x140:
            x -= 0x200
        if y > 0x140:
            y -= 0x200
        if flip_all:
            x = 320 - x - 16
            y = 256 - y - 16
            flipx = not flipx
            flipy = not flipy
        x += X_OFF
        y += Y_OFF
        if x <= -16 or x >= SCREEN_W or y <= VIS_TOP - 16 or y >= VIS_TOP + SCREEN_H:
            continue
        base = colour * 16
        src = OBJ_BASE + code * 128
        for ty in range(16):
            py = y + ty
            r = py - VIS_TOP
            if r < 0 or r >= SCREEN_H:
                continue
            sy = 15 - ty if flipy else ty
            row = rom[src + sy * 8: src + sy * 8 + 8]
            o = r * SCREEN_W
            for tx in range(16):
                px = x + tx
                if px < 0 or px >= SCREEN_W:
                    continue
                sx = 15 - tx if flipx else tx
                b = row[sx >> 1]
                pen = (b >> 4) if (sx & 1) == 0 else (b & 0xf)
                if pen == 0:
                    continue
                if claimed[o + px]:
                    continue
                claimed[o + px] = 1
                if blocked[o + px]:
                    continue
                out[o + px] = base + pen
                drawn[o + px] = 1


def to_rgb(st, idx, drawn):
    rgb = bytearray(SCREEN_W * SCREEN_H * 3)
    for i in range(SCREEN_W * SCREEN_H):
        r, g, b = rgb_of(st.pal[idx[i]]) if drawn[i] else rgb_of(st.pal[0])
        rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = r, g, b
    return rgb


def mame_rgb(st):
    """MAME's own output for the frame, unpacked from screen:pixels()."""
    rgb = bytearray(SCREEN_W * SCREEN_H * 3)
    px = st.pixels
    for i in range(SCREEN_W * SCREEN_H):
        v = px[i * 4] | (px[i * 4 + 1] << 8) | (px[i * 4 + 2] << 16)
        rgb[i * 3] = (v >> 16) & 0xff
        rgb[i * 3 + 1] = (v >> 8) & 0xff
        rgb[i * 3 + 2] = v & 0xff
    return rgb


def main():
    skip = {i + 1 for i, a in enumerate(sys.argv) if a in ('--png', '--idx')}
    args = [a for i, a in enumerate(sys.argv) if i > 0 and not a.startswith('--') and i not in skip]
    flags = {a for a in sys.argv[1:] if a.startswith('--')}
    if len(args) < 2:
        sys.exit(__doc__)
    st = State(args[0])
    rom = open(args[1], 'rb').read()
    idx, drawn = render(st, rom)
    ours = to_rgb(st, idx, drawn)
    theirs = mame_rgb(st)

    bad = [i for i in range(SCREEN_W * SCREEN_H)
           if ours[i * 3:i * 3 + 3] != theirs[i * 3:i * 3 + 3]]
    if '--png' in sys.argv:
        import pngio
        pngio.write(sys.argv[sys.argv.index('--png') + 1], SCREEN_W, SCREEN_H, ours)
    if '--idx' in sys.argv:
        with open(sys.argv[sys.argv.index('--idx') + 1], 'wb') as f:
            f.write(idx.tobytes())
    if '--quiet' not in flags:
        print(f'frame {st.frame}: {len(bad)} of {SCREEN_W * SCREEN_H} pixels differ')
        for i in bad[:8]:
            x, y = i % SCREEN_W, i // SCREEN_W
            print(f'  ({x:3d},{y:3d}) ours {tuple(ours[i*3:i*3+3])} '
                  f'mame {tuple(theirs[i*3:i*3+3])}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
