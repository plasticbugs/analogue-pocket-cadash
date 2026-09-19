// Menu-reset gate: platform/pocket/interface/interact.sv must reset the
// machine when a switch write changes something and must not when the Pocket
// simply writes the same word again, which it does whenever the menu closes.
#include "Vinteract.h"
#include "verilated.h"
#include <cstdio>
static Vinteract *d;
static void tick() { d->clk_74a = 0; d->clk_sync = 0; d->eval(); d->clk_74a = 1; d->clk_sync = 1; d->eval(); }
// write one bridge register, then report whether a reset followed
static bool wr(unsigned addr, unsigned data) {
    d->bridge_addr = addr; d->bridge_wr_data = data; d->bridge_wr = 1; tick();
    d->bridge_wr = 0;
    bool seen = false;
    for (int i = 0; i < 9000; i++) { tick(); if (d->reset_sw) seen = true; }
    return seen;
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vinteract; d->reset_n = 1; d->bridge_wr = 0; d->bridge_rd = 0;
    for (int i = 0; i < 20; i++) tick();
    int bad = 0;
    auto expect = [&](const char *what, bool got, bool want) {
        printf("  %-52s %s  %s\n", what, got ? "RESET   " : "no reset", got == want ? "ok" : "WRONG");
        if (got != want) bad++;
    };
    expect("DIPs written for the first time (0 -> 0x2C)",   wr(0xF1000000, 0x2C), true);
    expect("menu closes: the same DIP word again",          wr(0xF1000000, 0x2C), false);
    expect("and again",                                     wr(0xF1000000, 0x2C), false);
    expect("a DIP really changes (0x2C -> 0x2D)",           wr(0xF1000000, 0x2D), true);
    expect("a display option (modifiers) changes",          wr(0xF2000000, 0x02), false);
    expect("extra DIPs rewritten unchanged (0 -> 0)",       wr(0xF4000000, 0x00), false);
    expect("extra DIPs change",                             wr(0xF4000000, 0x01), true);
    expect("service switch rewritten unchanged",            wr(0xF0000010, 0x00), false);
    expect("service switch changes",                        wr(0xF0000010, 0x01), true);
    expect("Reset Core, always",                            wr(0xF0000000, 0x01), true);
    expect("Reset Core, again",                             wr(0xF0000000, 0x01), true);
    printf(bad ? "FAIL  %d wrong\n" : "PASS  the menu no longer restarts the game\n", bad);
    delete d; return bad ? 1 : 0;
}
