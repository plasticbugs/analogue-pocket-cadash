#!/bin/sh
# Pocket memory-subsystem gate: target/pocket/cadash_mem.sv and the real
# sdram_ctrl against a behavioural SDRAM chip.  The whole ROM image goes in
# through the download port and every region is read back through the core
# ports.
#
#   sim/run_mem.sh [rom] [gap in clocks, default 8 = the APF loader's rate]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
rom=${1:-$root/tmp/cadash.rom}
case "$rom" in /*) ;; *) rom="$(pwd)/$rom" ;; esac
[ -f "$rom" ] || { echo "no rom at $rom" >&2; exit 2; }
cd "$here"
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -Wno-EOFNEWLINE -Wno-VARHIDDEN \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
    -Wno-BLKANDNBLK -Wno-BLKSEQ -Wno-CASEINCOMPLETE -Wno-IMPLICIT -Wno-SYNCASYNCNET \
    --top-module tb_mem_top -Mdir obj_mem \
    ../target/pocket/cadash_mem.sv ../target/pocket/sdram_ctrl.sv \
    sdram_model.sv tb_mem_top.sv tb_mem.cpp > obj_mem.log 2>&1 \
    || { tail -40 obj_mem.log; exit 1; }
exec ./obj_mem/Vtb_mem_top "$rom" "${2:-8}"
