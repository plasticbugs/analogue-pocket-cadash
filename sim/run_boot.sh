#!/bin/sh
# Boot gate: run the whole machine from reset and check that the frame it
# reaches is the one MAME reaches.
#
# MAME's attract mode holds the Taito title screen still from frame 127 to
# frame 430 (tools/find_static.lua found the run), so the comparison does not
# depend on the two machines counting frames the same way -- anything the core
# produces inside that window has to match it exactly.
#
#   sim/run_boot.sh [frames]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
frames=${1:-150}
rom=${ROM:-$root/tmp/cadash.rom}
state=$root/ref/states/f000300.bin
[ -f "$state" ] || { echo "no reference state: run tools/dump_states.sh first" >&2; exit 2; }

mkdir -p "$root/artifacts/model" "$root/artifacts/system"
python3 "$root/tools/render_model.py" "$state" "$rom" \
    --idx "$root/artifacts/model/f000300.idx" --quiet

"$here/run_system.sh" "$rom" -frames "$frames"

echo
if python3 "$root/tools/diff_index.py" \
        "$root/artifacts/system/frame.idx" "$root/artifacts/model/f000300.idx"; then
    echo "PASS  the machine reaches MAME's title screen, pixel for pixel"
else
    echo "FAIL  the machine's frame $frames differs from MAME's title screen"
    exit 1
fi
