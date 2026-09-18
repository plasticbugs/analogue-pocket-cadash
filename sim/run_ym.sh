#!/bin/sh
# YM2151 on its own, driven the way the core drives it.  Seconds, not minutes.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -Wno-EOFNEWLINE -Wno-WIDTHEXPAND \
    -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-IMPLICIT \
    -Wno-LATCH -Wno-COMBDLY -Wno-BLKSEQ -Wno-PINMISSING -Wno-UNDRIVEN \
    -Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-SYNCASYNCNET \
    --top-module tb_ym_top -Mdir obj_ym \
    ../modules/sound-jt51/*.v tb_ym_top.sv tb_ym.cpp > obj_ym.log 2>&1 \
    || { tail -30 obj_ym.log; exit 1; }
exec ./obj_ym/Vtb_ym_top
