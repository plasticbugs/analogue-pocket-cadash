#!/bin/sh
# Menu-reset gate for platform/pocket/interface/interact.sv.
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j "${JOBS:-8}" -O2 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PROCASSINIT -Wno-INITIALDLY \
    --top-module interact -Mdir obj_interact \
    ../platform/pocket/interface/interact.sv ../platform/pocket/helpers/synch_3.sv \
    tb_interact.cpp > obj_interact.log 2>&1 || { tail -30 obj_interact.log; exit 1; }
exec ./obj_interact/Vinteract
