#!/usr/bin/env python3
"""Compare the core's recorded sound with MAME's, second by second.

Both are mono 16-bit WAVs at 48 kHz: the core's from sim/run_system.sh, MAME's
from -wavwrite.  METHODOLOGY section 4: same command, same window, compare
peak and RMS -- a ratio, not an eyeball.

Usage:
    compare_audio.py <core.wav> <mame.wav> [tolerance-percent]
"""
import struct, sys, wave


def read(path):
    w = wave.open(path)
    n, fr = w.getnframes(), w.getframerate()
    return struct.unpack('<%dh' % n, w.readframes(n)), fr


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    a, fra = read(sys.argv[1])
    b, frb = read(sys.argv[2])
    if fra != frb:
        sys.exit(f'sample rates differ: {fra} and {frb}')

    seconds = min(len(a), len(b)) // fra
    worst = 0.0
    print(f'{"second":>7}  {"core rms":>9} {"mame rms":>9}  '
          f'{"core peak":>9} {"mame peak":>9}   diff')
    for s in range(seconds):
        sa, sb = a[s * fra:(s + 1) * fra], b[s * fra:(s + 1) * fra]
        ra = (sum(x * x for x in sa) / len(sa)) ** 0.5
        rb = (sum(x * x for x in sb) / len(sb)) ** 0.5
        pa, pb = max(abs(x) for x in sa), max(abs(x) for x in sb)
        d = 0.0 if rb < 1 and ra < 1 else abs(ra - rb) / max(rb, 1) * 100
        worst = max(worst, d)
        print(f'{s:>7}  {ra:9.1f} {rb:9.1f}  {pa:9d} {pb:9d}   {d:5.1f}%')

    print(f'\nworst RMS difference over {seconds} s: {worst:.1f}% '
          f'(tolerance {tol:.0f}%)')
    return 0 if worst <= tol else 1


if __name__ == '__main__':
    sys.exit(main())
