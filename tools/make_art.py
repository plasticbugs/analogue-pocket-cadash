#!/usr/bin/env python3
"""Build the Pocket's core icon and platform banner from the core's own output.

Both are raw RGB565, little-endian, no header: the icon is 36x36 and the
platform image 521x165 (which is where those byte counts come from -- 2,592
and 171,930).  The pictures are crops of frames the reference renderer
produces, scaled by whole numbers only, so what the Pocket shows is literally
what the core draws.

Usage:
    make_art.py <state.bin> <image.rom>
"""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import pngio
from render_model import State, render, to_rgb, SCREEN_W, SCREEN_H

ICON_W = ICON_H = 36
BAN_W, BAN_H = 521, 165


def crop_scale(src, x0, y0, w, h, scale):
    out = bytearray(w * scale * h * scale * 3)
    for y in range(h * scale):
        for x in range(w * scale):
            s = ((y0 + y // scale) * SCREEN_W + x0 + x // scale) * 3
            d = (y * w * scale + x) * 3
            out[d:d + 3] = src[s:s + 3]
    return out, w * scale, h * scale


def pad(rgb, w, h, W, H):
    """Centre a smaller picture in a W x H field."""
    out = bytearray(W * H * 3)
    ox, oy = (W - w) // 2, (H - h) // 2
    for y in range(h):
        d = ((oy + y) * W + ox) * 3
        out[d:d + w * 3] = rgb[y * w * 3:(y + 1) * w * 3]
    return out


def rgb565(rgb, w, h):
    out = bytearray(w * h * 2)
    for i in range(w * h):
        r, g, b = rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        out[i * 2], out[i * 2 + 1] = v & 0xff, v >> 8
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    st = State(sys.argv[1])
    rom = open(sys.argv[2], 'rb').read()
    idx, drawn = render(st, rom)
    frame = to_rgb(st, idx, drawn)

    # the icon: the player, at the scale the game draws him
    icon, w, h = crop_scale(frame, 146, 160, ICON_W, ICON_H, 1)
    open('pkg/pocket/Cores/plasticbugs.cadash/icon.bin', 'wb').write(rgb565(icon, w, h))
    pngio.write('pkg/pocket/Cores/plasticbugs.cadash/icon_preview.png', w, h, icon)

    # the banner: a 260x82 slice of the cave at double size, centred
    ban, w, h = crop_scale(frame, 28, 118, 260, 82, 2)
    ban = pad(ban, w, h, BAN_W, BAN_H)
    open('pkg/pocket/Platforms/_images/cadash.bin', 'wb').write(rgb565(ban, BAN_W, BAN_H))
    pngio.write('pkg/pocket/Platforms/_images/cadash_preview.png', BAN_W, BAN_H, ban)
    print('wrote the icon and the platform image')


if __name__ == '__main__':
    main()
