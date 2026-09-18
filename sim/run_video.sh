#!/bin/sh
# Frozen-state video gate: load a dumped MAME frame into the RTL, render it,
# and diff the palette indices against tools/render_model.py, which is
# pixel-identical to MAME.
#
#   sim/run_video.sh [state.bin ...]
#
# With no arguments it runs every state in ref/states.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
# resolve any state paths before changing directory
args=""
for a in "$@"; do
    case "$a" in /*) args="$args $a" ;; *) args="$args $(pwd)/$a" ;; esac
done
rom=${ROM:-$root/tmp/cadash.rom}
lat=${LAT:-12}
[ -f "$rom" ] || python3 "$root/tools/mra_build.py" "$root/cadash.mra" "$root/cadash" "$rom" >/dev/null

cd "$here"
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    --top-module tb_video_top -Mdir obj_video \
    ../rtl/video_timing.sv ../rtl/tilemap_line.sv ../rtl/sprite_line.sv \
    ../rtl/cadash_video.sv tb_video_top.sv tb_video.cpp > obj_video.log 2>&1 \
    || { tail -40 obj_video.log; exit 1; }

mkdir -p "$root/artifacts/rtl" "$root/artifacts/model"
[ -n "$args" ] && states="$args" || states=$(ls "$root"/ref/states/*.bin)

fail=0
for s in $states; do
    n=$(basename "$s" .bin)
    printf '%-10s ' "$n"
    python3 "$root/tools/render_model.py" "$s" "$rom" --idx "$root/artifacts/model/$n.idx" --quiet
    if ! msg=$(./obj_video/Vtb_video_top "$s" "$rom" -o "$root/artifacts/rtl/$n.idx" -lat "$lat" 2>&1); then
        echo "BENCH FAILED  $msg"; fail=1; continue
    fi
    if out=$(python3 "$root/tools/diff_index.py" "$root/artifacts/rtl/$n.idx" "$root/artifacts/model/$n.idx"); then
        echo "PASS  $msg"
    else
        echo "FAIL  $msg"; echo "$out" | sed 's/^/           /'; fail=1
    fi
done
[ $fail = 0 ] && echo "every state matches the reference renderer" || { echo FAILURES; exit 1; }
