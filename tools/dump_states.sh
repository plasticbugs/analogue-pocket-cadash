#!/bin/sh
# Capture the reference states the video bench runs against.
#
# The frames are chosen from tools/probe_sprites.lua's survey of a 75-second
# attract-mode run: the title screen, several points of the demo, and the
# frames with the heaviest sprite load found anywhere in it (859 puts 68
# sprites on one scanline, 2597 puts 145 on the screen).
#
# No coin is inserted: the attract demo plays the game itself and is where the
# busy frames are, and leaving the inputs alone keeps the frame numbering the
# same as the probe's.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
frames=${FRAMES:-300,600,859,900,1000,1089,1464,2597,2715,3600}
DUMPFRAMES="$frames" DUMP_DIR="$root/ref/states" \
    "$root/tools/mame.sh" -seconds_to_run 65 -autoboot_script "$root/tools/dump_state.lua"
ls -1 "$root/ref/states"/*.bin | wc -l | xargs echo "states:"
