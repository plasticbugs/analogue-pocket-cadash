#!/bin/sh
# Check the reference renderer against MAME's own output on every saved state.
# This is the gate the renderer has to keep passing: it is the spec the RTL is
# written against, so a difference here invalidates every video test below it.
root=$(cd "$(dirname "$0")/.." && pwd)
rom=${ROM:-$root/tmp/cadash.rom}
[ -f "$rom" ] || python3 "$root/tools/mra_build.py" "$root/cadash.mra" "$root/cadash" "$rom" >/dev/null
fail=0
for f in "$root"/ref/states/*.bin; do
    if out=$(python3 "$root/tools/render_model.py" "$f" "$rom" 2>&1); then
        echo "ok   $(basename "$f")  $(echo "$out" | head -1)"
    else
        echo "FAIL $(basename "$f")"
        echo "$out" | sed 's/^/     /'
        fail=1
    fi
done
exit $fail
