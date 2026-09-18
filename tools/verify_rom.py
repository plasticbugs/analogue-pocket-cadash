#!/usr/bin/env python3
"""Check the .rom image cadash.mra builds against MAME's own loaded regions.

MAME is the oracle for the ROM path too: tools/dump_regions.lua writes out the
bytes MAME hands to each chip, and this compares them with the corresponding
slice of the image.  A mismatch here means the core would be fed different
bytes than the game expects, which is the cheapest possible bug to find and
the most expensive to find later.

Usage:
    verify_rom.py <image.rom> <region_dir>
"""
import sys

REGIONS = [
    ('maincpu',   0x000000, 0x080000),
    ('audiocpu',  0x080000, 0x010000),
    ('tc0100scn', 0x090000, 0x080000),
    ('pc090oj',   0x110000, 0x080000),
]
TOTAL = 0x190000


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = open(sys.argv[1], 'rb').read()
    d = sys.argv[2].rstrip('/')

    bad = 0
    if len(image) != TOTAL:
        print(f'FAIL: image is {len(image)} bytes, expected {TOTAL}')
        bad += 1

    for name, base, length in REGIONS:
        want = open(f'{d}/{name}.bin', 'rb').read()
        if len(want) != length:
            print(f'FAIL: MAME region {name} is {len(want):#x} bytes, expected {length:#x}')
            bad += 1
            continue
        got = image[base:base + length]
        if got == want:
            print(f'ok   {name:<10} {base:#08x}+{length:#07x}')
            continue
        first = next(i for i in range(length) if got[i] != want[i])
        ndiff = sum(1 for i in range(length) if got[i] != want[i])
        print(f'FAIL {name:<10} {ndiff} bytes differ, first at region offset '
              f'{first:#x}: image {got[first]:#04x} vs MAME {want[first]:#04x}')
        bad += 1

    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
