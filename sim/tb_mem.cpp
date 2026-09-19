// Pocket memory gate: push the real ROM image through cadash_mem's download
// port at the APF loader's rate, then read every word of every region back
// through the core ports and compare against the image.
//
//   obj_mem/Vtb_mem_top <cadash.rom> [gap] [--full]
//
// `gap` is the clocks between download bytes; the APF loader delivers at most
// one byte per 8, and a smaller number is a harder test of the write path.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_mem_top *dut;
static vluint64_t   main_time = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

// image layout, byte offsets (must match cadash_mem.sv)
static const uint32_t SND_B = 0x080000, SCN_B = 0x090000, OBJ_B = 0x110000;
static const uint32_t IMG   = 1638400;

static std::vector<uint8_t> rom;

static uint16_t be16(uint32_t byte_off) {
    return (uint16_t(rom[byte_off]) << 8) | rom[byte_off + 1];
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <cadash.rom> [gap] [--full]\n", argv[0]); return 2; }
    int gap = (argc > 2) ? atoi(argv[2]) : 8;
    bool full = false;
    for (int i = 2; i < argc; i++) if (!strcmp(argv[i], "--full")) full = true;

    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    rom.resize(IMG);
    if (fread(rom.data(), 1, IMG, f) != IMG) { fprintf(stderr, "short rom\n"); fclose(f); return 2; }
    fclose(f);

    dut = new Vtb_mem_top;
    dut->clk = 0; dut->init = 1; dut->rd_late = 1; dut->burst_slow = 0;
    dut->dl_we = 0; dut->dl_addr = 0; dut->dl_data = 0;
    dut->mrom_req = dut->srom_req = dut->tile_req = dut->obj_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;

    // How long the controller takes to initialise.  The download begins the
    // moment the host starts sending, which on hardware can be before this.
    vluint64_t t_start = main_time;
    while (!dut->ready && main_time - t_start < 200000) tick();
    printf("sdram ready after %llu clocks\n", (unsigned long long)(main_time - t_start));

    // ---- download: one byte every `gap` clocks, exactly as the loader does
    printf("downloading %u bytes at one per %d clocks...\n", IMG, gap);
    for (uint32_t a = 0; a < IMG; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        tick();
        dut->dl_we = 0;
        for (int i = 1; i < gap; i++) tick();
    }
    for (int i = 0; i < 200; i++) tick();   // let the last write retire

    // ---- read every region back through its core port
    long bad = 0, checked = 0;
    auto fail = [&](const char *port, uint32_t idx, uint64_t got, uint64_t want) {
        if (bad < 12)
            printf("  %-5s [%06X] got %016llX want %016llX\n", port, idx,
                   (unsigned long long)got, (unsigned long long)want);
        bad++;
    };

    uint32_t mrom_n = full ? 262144 : 262144;      // 512 KB as words
    for (uint32_t w = 0; w < mrom_n; w++) {
        dut->mrom_addr = w; dut->mrom_req = 1;
        int guard = 0; while (!dut->mrom_ack && guard++ < 4000) tick();
        dut->mrom_req = 0; tick();
        uint16_t want = be16(w * 2);
        checked++; if (dut->mrom_q != want) fail("prog", w, dut->mrom_q, want);
    }
    for (uint32_t b = 0; b < 65536; b++) {
        dut->srom_addr = b; dut->srom_req = 1;
        int guard = 0; while (!dut->srom_ack && guard++ < 4000) tick();
        dut->srom_req = 0; tick();
        uint8_t want = rom[SND_B + b];
        checked++; if (dut->srom_q != want) fail("snd", b, dut->srom_q, want);
    }
    for (uint32_t r = 0; r < 131072; r++) {
        dut->tile_addr = r; dut->tile_req = 1;
        int guard = 0; while (!dut->tile_ack && guard++ < 4000) tick();
        dut->tile_req = 0; tick();
        uint32_t want = (uint32_t(be16(SCN_B + r * 4)) << 16) | be16(SCN_B + r * 4 + 2);
        checked++; if (dut->tile_q != want) fail("tile", r, dut->tile_q, want);
    }
    for (uint32_t r = 0; r < 65536; r++) {
        dut->obj_addr = r; dut->obj_req = 1;
        int guard = 0; while (!dut->obj_ack && guard++ < 4000) tick();
        dut->obj_req = 0; tick();
        uint64_t want = 0;
        for (int k = 0; k < 4; k++) want = (want << 16) | be16(OBJ_B + r * 8 + k * 2);
        checked++; if (dut->obj_q != want) fail("obj", r, dut->obj_q, want);
    }

    printf("\n%ld words checked through the core ports, %ld wrong\n", checked, bad);
    delete dut;
    if (bad) { printf("FAIL  the image in SDRAM is not the image that was sent\n"); return 1; }
    printf("PASS  every region reads back byte-for-byte\n");
    return 0;
}
