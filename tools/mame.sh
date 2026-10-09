#!/bin/sh
# Run MAME on cadash headless and deterministic.
# Always pass -seconds_to_run; ending a run from Lua has proved unreliable.
#
# Nothing here may touch the display.  `-video none` stops MAME rendering to a
# window but does NOT stop it creating one, and MAME's own defaults are
# fullscreen (window 0, maximize 1) -- which on macOS makes the desktop jump
# to another Space every time a probe runs.  Three measures, because they
# fail independently: SDL_VIDEODRIVER=dummy keeps SDL from opening the
# display at all (it is read before MAME parses anything), -videodriver dummy
# says the same through MAME, and -window -nomaximize means that if a window
# is created regardless it is a small one that steals no Space.  Never pass
# -fullscreen.
root=$(cd "$(dirname "$0")/.." && pwd)
SDL_VIDEODRIVER=dummy \
exec mame cadash -rompath "$root/.mame/roms" \
    -video none -videodriver dummy -window -nomaximize \
    -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$root/.mame/nvram" \
    "$@"
