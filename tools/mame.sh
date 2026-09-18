#!/bin/sh
# Run MAME on cadash headless and deterministic.
# Always pass -seconds_to_run; ending a run from Lua has proved unreliable.
root=$(cd "$(dirname "$0")/.." && pwd)
exec mame cadash -rompath "$root/.mame/roms" \
    -video none -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$root/.mame/nvram" \
    "$@"
