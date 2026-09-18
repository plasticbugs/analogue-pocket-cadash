// Driver for the whole-machine bench.
//
//   Vtb_system_top <image.rom> [-frames N] [-o dir] [-lat N] [-coin F] [-start F]
//
// Runs the real program on both CPUs against a model of the Pocket's SDRAM and
// reports what the machine did: whether the 68000 stayed out of halt, how many
// frames it produced, whether any scanline overran its budget, and what the
// picture and the sound look like.  Every captured frame is written as a
// 320x240 array of palette indices, the same format tools/render_model.py
// writes with --idx, so it can be turned into a PNG with tools/idx2png.py.
//
// A frame is 1.6 million clocks, so this is for questions about the machine --
// does it boot, do the interrupts run, does the sound CPU answer -- and
// sim/run_video.sh is for anything about the picture itself.
#include "Vtb_system_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int W = 320, H = 240;
static const size_t PROG_BASE = 0x000000, PROG_LEN = 0x80000;
static const size_t SND_BASE  = 0x080000, SND_LEN  = 0x10000;
static const size_t SCN_BASE  = 0x090000, SCN_LEN  = 0x80000;
static const size_t OBJ_BASE  = 0x110000, OBJ_LEN  = 0x80000;

static Vtb_system_top *dut;

static void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
}

static void load(int sel, uint32_t addr, uint64_t data) {
    dut->ld_sel = sel; dut->ld_addr = addr; dut->ld_data = data; dut->ld_we = 1;
    tick();
    dut->ld_we = 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *rom_path = nullptr, *out_dir = nullptr;
    int frames = 240, lat = 12, coin_frame = 0, start_frame = 0;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-o")      && i + 1 < argc) out_dir = argv[++i];
        else if (!strcmp(argv[i], "-frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-lat")    && i + 1 < argc) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-coin")   && i + 1 < argc) coin_frame = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-start")  && i + 1 < argc) start_frame = atoi(argv[++i]);
        else if (!rom_path)                                   rom_path = argv[i];
    }
    if (!rom_path) {
        fprintf(stderr, "usage: %s <image.rom> [-frames N] [-o dir] [-lat N]"
                        " [-coin F] [-start F]\n", argv[0]);
        return 2;
    }

    FILE *rf = fopen(rom_path, "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", rom_path); return 2; }
    std::vector<uint8_t> rom(0x190000);
    if (fread(rom.data(), 1, rom.size(), rf) != rom.size()) {
        fprintf(stderr, "%s: expected %zu bytes\n", rom_path, rom.size());
        fclose(rf); return 2;
    }
    fclose(rf);

    dut = new Vtb_system_top;
    dut->reset   = 1;
    dut->rom_lat = lat;
    // Every input and DIP is active low; these are the factory settings from
    // docs/hardware.md section 5.
    dut->dswa = 0xff; dut->dswb = 0xff;
    dut->in0  = 0xff; dut->in1  = 0xff; dut->in2 = 0xff;
    tick(8);

    for (size_t i = 0; i < PROG_LEN / 2; i++)
        load(0, i, ((uint64_t)rom[PROG_BASE + i * 2] << 8) | rom[PROG_BASE + i * 2 + 1]);
    for (size_t i = 0; i < SND_LEN; i++)
        load(1, i, rom[SND_BASE + i]);
    for (size_t i = 0; i < SCN_LEN / 4; i++) {
        const uint8_t *p = &rom[SCN_BASE + i * 4];
        load(2, i, ((uint64_t)p[0] << 24) | ((uint64_t)p[1] << 16) |
                   ((uint64_t)p[2] << 8) | p[3]);
    }
    for (size_t i = 0; i < OBJ_LEN / 8; i++) {
        const uint8_t *p = &rom[OBJ_BASE + i * 8];
        uint64_t v = 0;
        for (int k = 0; k < 8; k++) v = (v << 8) | p[k];
        load(3, i, v);
    }

    dut->reset = 0;
    tick(64);

    // ---- run ----
    std::vector<uint16_t> idx(W * H, 0);
    long  clocks = 0, halted_clocks = 0;
    int   frame = 0, prev_v = -1, x = 0;
    int   overrun_count = 0, last_overrun = -1;
    int   worst_line = 0, worst_frame = 0, first_overrun = -1;
    long  snd_nonzero = 0, snd_peak = 0;
    bool  vb_prev = false;

    const long limit = (long)frames * 262 * 436 * 14 + 4000000;
    while (clocks < limit && frame <= frames) {
        bool was_ce = dut->ce_pix;
        tick();
        clocks++;
        if (dut->dbg_halted) halted_clocks++;
        // The very first frame legitimately overruns: sprite RAM comes up
        // uninitialised, which parks all 256 entries on the same few lines.
        // What matters is whether it still happens once the game has cleared
        // its RAM.
        if (dut->dbg_line_overrun != overrun_count) {
            overrun_count = dut->dbg_line_overrun;
            if (first_overrun < 0) first_overrun = frame;
            last_overrun = frame;
        }

        int s = (int16_t)dut->sound;
        if (s) snd_nonzero++;
        if (abs(s) > snd_peak) snd_peak = abs(s);

        bool vb = dut->vblank;
        if (vb && !vb_prev) frame++;
        vb_prev = vb;

        if (was_ce) {
            if ((int)dut->vcnt != prev_v) {
                prev_v = dut->vcnt;
                x = 0;
                int line = dut->dbg_tile_cycles + dut->dbg_obj_cycles;
                if (line > worst_line) { worst_line = line; worst_frame = frame; }
            }
            // capture the last frame asked for
            if (frame == frames && dut->de && prev_v >= 0 && prev_v < H && x < W)
                idx[prev_v * W + x++] = dut->pix_index;
        }

        // hold a coin or a start button for eight frames
        auto held = [&](int from) { return from && frame >= from && frame < from + 8; };
        dut->in2 = 0xff & ~((held(coin_frame) ? 0x01 : 0) |
                            (held(start_frame) ? 0x08 : 0));
    }

    int nonblank = 0;
    for (int i = 0; i < W * H; i++) if (idx[i]) nonblank++;

    if (out_dir) {
        std::string p = std::string(out_dir) + "/frame.idx";
        FILE *of = fopen(p.c_str(), "wb");
        if (of) { fwrite(idx.data(), 2, idx.size(), of); fclose(of); }
    }

    printf("frames %d, %ld clocks, halted for %ld\n", frame, clocks, halted_clocks);
    printf("picture: %d of %d indices non-zero\n", nonblank, W * H);
    printf("sound:   %ld non-zero samples, peak %ld\n", snd_nonzero, snd_peak);
    printf("worst line %d of 6104 clocks, frame %d\n", worst_line, worst_frame);
    if (first_overrun >= 0)
        printf("lines dropped: %d, frames %d..%d\n",
               overrun_count, first_overrun, last_overrun);
    else
        printf("lines dropped: none\n");

    bool ok = (halted_clocks == 0) && (nonblank > 0) && (last_overrun <= 1);
    delete dut;
    return ok ? 0 : 1;
}
