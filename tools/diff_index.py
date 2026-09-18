#!/usr/bin/env python3
"""Diff two 320x240 palette-index frames, as the video bench writes them.

Reports how many indices differ, where the first few are, and which 8x8 cells
hold the worst of them -- a bug in one layer or one sprite shows up as a
cluster, which is most of the diagnosis.

Usage:
    diff_index.py <a.idx> <b.idx>
"""
import sys
from collections import Counter

W, H = 320, 240


def load(path):
    d = open(path, 'rb').read()
    if len(d) != W * H * 2:
        sys.exit(f'{path}: {len(d)} bytes, expected {W * H * 2}')
    return [d[i * 2] | (d[i * 2 + 1] << 8) for i in range(W * H)]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    bad = [i for i in range(W * H) if a[i] != b[i]]
    if not bad:
        return 0
    print(f'{len(bad)} of {W * H} indices differ')
    for i in bad[:8]:
        print(f'  ({i % W:3d},{i // W:3d}) rtl {a[i]:#05x}  model {b[i]:#05x}')
    cells = Counter(((i % W) // 8, (i // W) // 8) for i in bad)
    worst = ' '.join(f'({x},{y}):{n}' for (x, y), n in cells.most_common(6))
    print(f'  worst 8x8 cells (col,row): {worst}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
