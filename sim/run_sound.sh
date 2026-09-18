#!/bin/sh
# Sound gate: play the coin sound on both the core and MAME and compare them.
#
# MAME's attract mode is silent -- verified, not assumed -- so the comparison
# needs a coin.  Both sides insert one at frame 120 and record 200 frames.
#
#   sim/run_sound.sh [frames]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
frames=${1:-200}
rom=${ROM:-$root/tmp/cadash.rom}
mkdir -p "$root/artifacts/system" "$root/tmp/audio"

echo "--- MAME ---"
COIN=120 REPORT="$frames" OUT="$root/tmp/sound.txt" \
    "$root/tools/mame.sh" -seconds_to_run $((frames / 60 + 2)) \
    -autoboot_script "$root/tools/probe_sound.lua" \
    -wavwrite "$root/tmp/audio/coin.wav" >/dev/null 2>&1
cat "$root/tmp/sound.txt"

echo
echo "--- the core ---"
"$here/run_system.sh" "$rom" -frames "$frames" -coin 120 | \
    grep -E "^(sound|Z80|YM2151 registers|Z80 ROM bank)"

echo
python3 "$root/tools/compare_audio.py" \
    "$root/artifacts/system/sound.wav" "$root/tmp/audio/coin.wav"
