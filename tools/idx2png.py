#!/usr/bin/env python3
"""Turn a 320x240 palette-index frame into a PNG, using a state's palette.

Usage:
    idx2png.py <frame.idx> <state.bin> <out.png>
"""
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import pngio
from render_model import State, rgb_of, SCREEN_W, SCREEN_H


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    d = open(sys.argv[1], 'rb').read()
    st = State(sys.argv[2])
    rgb = bytearray(SCREEN_W * SCREEN_H * 3)
    for i in range(SCREEN_W * SCREEN_H):
        r, g, b = rgb_of(st.pal[d[i * 2] | (d[i * 2 + 1] << 8)])
        rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = r, g, b
    pngio.write(sys.argv[3], SCREEN_W, SCREEN_H, rgb)


if __name__ == '__main__':
    main()
