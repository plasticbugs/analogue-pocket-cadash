// Play one note on the YM2151, driven the way the core drives it, and report
// whether anything came out.  See sim/tb_ym_top.sv for why this exists.
#include "Vtb_ym_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vtb_ym_top *dut;

static void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
}

// A register write the way the Z80 does it: address, then data, waiting for
// the chip to stop being busy in between.
static void wr(uint8_t reg, uint8_t val) {
    for (int phase = 0; phase < 2; phase++) {
        int guard = 0;
        while (dut->busy && guard++ < 20000) tick();
        dut->wr = 1; dut->a0 = phase; dut->din = phase ? val : reg;
        tick();
        dut->wr = 0;
        // hold until the chip has taken it
        guard = 0;
        while (dut->pend && guard++ < 200) tick();
        tick(4);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_ym_top;
    dut->reset = 1;
    tick(64);
    dut->reset = 0;
    tick(2000);

    // CT1 and CT2, which is the core's Z80 ROM bank
    wr(0x1b, 0xc0);
    tick(4000);
    printf("after writing 0x1B = 0xC0:  ct1 %d  ct2 %d  (expect 1 and 1)\n",
           dut->ct1, dut->ct2);

    // one operator, full output, fast attack, no decay, on channel 0
    wr(0x20, 0xc7);     // channel 0: both speakers, feedback 0, algorithm 7
    wr(0x28, 0x4a);     // key code
    wr(0x30, 0x00);     // key fraction
    for (int op = 0; op < 4; op++) {
        wr(0x40 + op * 8, 0x01);   // detune 0, multiple 1
        wr(0x60 + op * 8, 0x00);   // total level 0 = loudest
        wr(0x80 + op * 8, 0x1f);   // attack rate maximum
        wr(0xa0 + op * 8, 0x00);   // first decay off
        wr(0xc0 + op * 8, 0x00);   // second decay off
        wr(0xe0 + op * 8, 0x00);   // sustain level 0, release 0
    }
    wr(0x08, 0x78);     // key on, all four operators of channel 0

    long peak = 0, nonzero = 0;
    for (int i = 0; i < 400000; i++) {
        tick();
        int v = (int16_t)dut->left;
        if (v) nonzero++;
        if (labs(v) > peak) peak = labs(v);
    }
    printf("after key-on: %ld non-zero samples in 400,000 clocks, peak %ld\n",
           nonzero, peak);

    bool ok = dut->ct1 && dut->ct2 && peak > 100;
    printf("%s\n", ok ? "PASS  the chip takes writes and makes sound"
                      : "FAIL  the chip is not responding the way it is driven");
    delete dut;
    return ok ? 0 : 1;
}
