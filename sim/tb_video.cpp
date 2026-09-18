// Driver for the frozen-state video bench.
//
//   Vtb_video_top <state.bin> <image.rom> -o <out.idx> [-lat N]
//
// Loads the state through the chips' CPU ports, lets one frame pass so the
// sprite table reaches the chip's buffer the way it does on hardware, and
// writes the next frame's 320x240 palette indices as little-endian u16 -- the
// same file tools/render_model.py writes with --idx.
//
// It also reports the worst line the frame cost, which is what says whether
// the renderer fits in the 6104 system clocks a scanline has
// (docs/core-design.md section 5).
#include "Vtb_video_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const int W = 320, H = 240;

// Where each region sits in the image cadash.mra builds.
static const size_t SCN_BASE = 0x090000, SCN_LEN = 0x80000;
static const size_t OBJ_BASE = 0x110000, OBJ_LEN = 0x80000;

static Vtb_video_top *dut;
static vluint64_t     main_time = 0;

static void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        main_time++;
    }
}

static void write_reg(int which, uint16_t addr, uint16_t data) {
    dut->vram_cs = dut->ctrl_cs = dut->spr_cs = dut->pal_cs = dut->sprctl_cs = 0;
    switch (which) {
        case 0: dut->vram_cs   = 1; break;
        case 1: dut->ctrl_cs   = 1; break;
        case 2: dut->spr_cs    = 1; break;
        case 3: dut->pal_cs    = 1; break;
        case 4: dut->sprctl_cs = 1; break;
    }
    dut->cpu_addr = addr;
    dut->cpu_din  = data;
    dut->cpu_we   = 1;
    tick();
    dut->vram_cs = dut->ctrl_cs = dut->spr_cs = dut->pal_cs = dut->sprctl_cs = 0;
    dut->cpu_we  = 0;
    tick();
}

struct State {
    uint32_t frame;
    uint16_t ctrl[8];
    std::vector<uint16_t> scn, spr, pal;
    uint16_t spr_ctrl, oj_ctrl;
};

static bool load_state(const char *path, State &s) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    char magic[4];
    uint32_t ver;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "CDST", 4)) {
        fprintf(stderr, "%s: not a Cadash state dump\n", path); fclose(f); return false;
    }
    if (fread(&ver, 4, 1, f) != 1 || ver != 2) {
        fprintf(stderr, "%s: version %u, expected 2\n", path, ver); fclose(f); return false;
    }
    bool ok = fread(&s.frame, 4, 1, f) == 1;
    s.scn.resize(32768); s.spr.resize(1024); s.pal.resize(4096);
    ok &= fread(s.ctrl, 2, 8, f) == 8;
    ok &= fread(s.scn.data(), 2, 32768, f) == 32768;
    ok &= fread(s.spr.data(), 2, 1024, f) == 1024;
    ok &= fread(&s.spr_ctrl, 2, 1, f) == 1;
    ok &= fread(&s.oj_ctrl, 2, 1, f) == 1;
    ok &= fread(s.pal.data(), 2, 4096, f) == 4096;
    fclose(f);
    if (!ok) fprintf(stderr, "%s: short read\n", path);
    return ok;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *state_path = nullptr, *rom_path = nullptr, *out_path = nullptr;
    int lat = 12;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc)        out_path = argv[++i];
        else if (!strcmp(argv[i], "-lat") && i + 1 < argc) lat = atoi(argv[++i]);
        else if (!state_path)                              state_path = argv[i];
        else if (!rom_path)                                rom_path = argv[i];
    }
    if (!state_path || !rom_path) {
        fprintf(stderr, "usage: %s <state.bin> <image.rom> -o <out.idx> [-lat N]\n", argv[0]);
        return 2;
    }

    State st;
    if (!load_state(state_path, st)) return 2;

    FILE *rf = fopen(rom_path, "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", rom_path); return 2; }
    std::vector<uint8_t> rom(0x190000);
    if (fread(rom.data(), 1, rom.size(), rf) != rom.size()) {
        fprintf(stderr, "%s: expected %zu bytes\n", rom_path, rom.size());
        fclose(rf); return 2;
    }
    fclose(rf);

    dut = new Vtb_video_top;
    dut->reset = 1;
    dut->rom_lat = lat;
    tick(8);
    dut->reset = 0;
    tick(4);

    // ---- graphics ROMs: big-endian bytes, as the image holds them ----
    for (size_t i = 0; i < SCN_LEN / 4; i++) {
        const uint8_t *p = &rom[SCN_BASE + i * 4];
        dut->tile_we = 1;
        dut->tile_waddr = i;
        dut->tile_wdata = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                          ((uint32_t)p[2] << 8)  | p[3];
        tick();
    }
    dut->tile_we = 0;
    for (size_t i = 0; i < OBJ_LEN / 8; i++) {
        const uint8_t *p = &rom[OBJ_BASE + i * 8];
        uint64_t v = 0;
        for (int k = 0; k < 8; k++) v = (v << 8) | p[k];
        dut->obj_we = 1;
        dut->obj_waddr = i;
        dut->obj_wdata = v;
        tick();
    }
    dut->obj_we = 0;

    // ---- the state, through the chips' own ports ----
    for (int i = 0; i < 8; i++)      write_reg(1, i, st.ctrl[i]);
    for (int i = 0; i < 32768; i++)  write_reg(0, i, st.scn[i]);
    for (int i = 0; i < 1024; i++)   write_reg(2, i, st.spr[i]);
    write_reg(2, 0x0dff, st.oj_ctrl);          // the chip's flip register
    write_reg(4, 0, st.spr_ctrl);              // sprite control at 080000
    for (int i = 0; i < 4096; i++) {
        write_reg(3, 0, i);                    // palette address port
        write_reg(3, 1, st.pal[i]);            // palette data port
    }

    // ---- let a whole frame pass, so the sprite table reaches the buffer ----
    int guard = 0;
    while (!(dut->vblank) && guard++ < 4000000) tick();
    while ((dut->vblank) && guard++ < 4000000) tick();
    while (!(dut->vblank) && guard++ < 4000000) tick();

    // ---- capture the next frame ----
    // Start inside vblank and run for exactly one raster, placing each pixel
    // by the line it belongs to: the display pipeline is two dots long, so a
    // frame's pixels do not start on a line boundary and counting them in
    // order silently slips a row.
    std::vector<uint16_t> idx(W * H, 0);
    int  captured = 0, worst_line = 0, worst_tile = 0, worst_obj = 0;
    bool overrun = false;
    while (!(dut->vblank) && guard++ < 4000000) tick();

    // While the frame is being rendered, read VRAM through the CPU port the
    // way the 68000 does.  The renderer shares that port and stalls for the
    // two clocks each read takes, so this is what proves the sharing is
    // transparent: the reads have to come back right *and* the picture has to
    // be unchanged.
    long reads = 0, bad_reads = 0;
    int  probe = 0, pending_addr = -1;
    int  probe_every = getenv("NOPROBE") ? 0 : 97;

    int prev_v = -1, x = 0;
    for (int dots = 0; dots < 262 * 436 + 4; ) {
        // A CPU read is asserted for one clock and answered on the next, so
        // it rides along with the normal loop rather than stealing ticks.
        if (pending_addr >= 0) {
            if (dut->cpu_dout != st.scn[pending_addr]) {
                if (bad_reads < 4)
                    printf("VRAM read %04x: got %04x, expected %04x\n",
                           pending_addr, dut->cpu_dout, st.scn[pending_addr]);
                bad_reads++;
            }
            reads++;
            pending_addr = -1;
            dut->vram_cs = 0;
        } else if (probe_every && (probe % probe_every) == 0) {
            pending_addr = (probe / probe_every * 1237) & 0x7fff;
            dut->vram_cs = 1; dut->cpu_we = 0; dut->cpu_addr = pending_addr;
        }
        probe++;

        bool was_ce = dut->ce_pix;
        tick();
        if (was_ce) {
            dots++;
            if ((int)dut->vcnt != prev_v) {
                prev_v = dut->vcnt;
                x = 0;
                int line = dut->tile_cycles + dut->obj_cycles;
                if (line > worst_line) {
                    worst_line = line;
                    worst_tile = dut->tile_cycles;
                    worst_obj  = dut->obj_cycles;
                }
            }
            if (dut->de && prev_v >= 0 && prev_v < H && x < W) {
                idx[prev_v * W + x++] = dut->pix_index;
                captured++;
            }
        }
        if (dut->line_overrun) overrun = true;
    }

    if (out_path) {
        FILE *of = fopen(out_path, "wb");
        if (!of) { fprintf(stderr, "cannot write %s\n", out_path); return 2; }
        fwrite(idx.data(), 2, idx.size(), of);
        fclose(of);
    }

    printf("%ld CPU reads through the shared port, %ld wrong\n", reads, bad_reads);
    printf("%d px, worst line %d clocks (tilemaps %d, sprites %d) of 6104%s\n",
           captured, worst_line, worst_tile, worst_obj,
           overrun ? "  OVERRUN" : "");
    delete dut;
    return (captured == W * H && !overrun && bad_reads == 0) ? 0 : 1;
}
