#!/bin/sh
# Fetch the reference material this project reads but does not vendor.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)

# MAME 0.288 sources for the driver and every Taito chip Cadash uses.
mkdir -p "$root/ref/mame"
for f in asuka.cpp tc0100scn.cpp tc0100scn.h pc090oj.cpp pc090oj.h \
         tc0110pcr.cpp tc0110pcr.h taitoio.cpp taitoio.h taitoipt.h; do
    curl -fsS -o "$root/ref/mame/$f" \
        "https://raw.githubusercontent.com/mamedev/mame/mame0288/src/mame/taito/$f"
done
for f in taitosnd.cpp taitosnd.h; do
    curl -fsS -o "$root/ref/mame/$f" \
        "https://raw.githubusercontent.com/mamedev/mame/mame0288/src/mame/shared/$f"
done

# The MiSTer Taito F2 core: its TC0100SCN, TC0110PCR, TC0220IOC and PC060HA
# RTL cover most of Cadash's chipset.
[ -d "$root/ref/taitof2" ] || git clone --depth 1 \
    https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer.git "$root/ref/taitof2"
