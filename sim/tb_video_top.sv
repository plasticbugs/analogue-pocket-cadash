//------------------------------------------------------------------------------
// Frozen-state video bench: the whole of cadash_video with the graphics ROMs
// modelled here, so a dumped MAME frame can be loaded through the chips' own
// CPU ports and rendered.
//
// Loading through the CPU ports rather than poking the memories directly means
// the bench also exercises the write paths the 68000 uses, and it is what lets
// the palette, the sprite control register and the chip's flip bit be set the
// way the game sets them.
//
// The ROM model has a settable latency so the bench can ask what the renderer
// does when SDRAM is slower than block RAM.
//------------------------------------------------------------------------------
`default_nettype none

module tb_video_top (
    input  logic        clk,
    input  logic        reset,

    // ---- loading ----
    input  logic        cpu_we,
    input  logic        vram_cs, ctrl_cs, spr_cs, pal_cs, sprctl_cs,
    input  logic [14:0] cpu_addr,
    input  logic [15:0] cpu_din,

    input  logic        tile_we,
    input  logic [16:0] tile_waddr,
    input  logic [31:0] tile_wdata,

    input  logic        obj_we,
    input  logic [15:0] obj_waddr,
    input  logic [63:0] obj_wdata,

    input  logic  [5:0] rom_lat,        // clocks a graphics read takes

    // ---- observation ----
    output logic        ce_pix,
    output logic [11:0] pix_index,
    output logic        de,
    output logic  [8:0] vcnt,
    output logic        vblank,
    output logic [15:0] tile_cycles,
    output logic [15:0] obj_cycles,
    output logic        line_overrun
);
    // ------------------------------------------------- graphics ROM model
    logic [31:0] tile_rom [0:131071];   // 512 KB as 8-pixel rows
    logic [63:0] obj_rom  [0:65535];    // 512 KB as 16-pixel rows

    logic        tile_req, tile_ack;
    logic [16:0] tile_addr;
    logic [31:0] tile_q;
    logic  [5:0] tile_cnt;

    always_ff @(posedge clk) begin
        if (tile_we) tile_rom[tile_waddr] <= tile_wdata;
        tile_ack <= 1'b0;
        if (!tile_req) begin
            tile_cnt <= '0;
        end else if (!tile_ack) begin
            if (tile_cnt >= rom_lat) begin
                tile_cnt <= '0;
                tile_ack <= 1'b1;
                tile_q   <= tile_rom[tile_addr];
            end else begin
                tile_cnt <= tile_cnt + 6'd1;
            end
        end
    end

    logic        obj_req, obj_ack;
    logic [15:0] obj_addr;
    logic [63:0] obj_q;
    logic  [5:0] obj_cnt;

    always_ff @(posedge clk) begin
        if (obj_we) obj_rom[obj_waddr] <= obj_wdata;
        obj_ack <= 1'b0;
        if (!obj_req) begin
            obj_cnt <= '0;
        end else if (!obj_ack) begin
            if (obj_cnt >= rom_lat) begin
                obj_cnt <= '0;
                obj_ack <= 1'b1;
                obj_q   <= obj_rom[obj_addr];
            end else begin
                obj_cnt <= obj_cnt + 6'd1;
            end
        end
    end

    // -------------------------------------------------------------- DUT
    logic [7:0] r, g, b;
    logic       hs, vs, hb;

    cadash_video u_video (
        .clk, .reset,
        .vram_cs, .ctrl_cs, .spr_cs, .pal_cs, .sprctl_cs,
        .cpu_addr, .cpu_din, .cpu_ds(2'b11), .cpu_we, .cpu_dout(),
        .tile_req, .tile_addr, .tile_ack, .tile_q,
        .obj_req,  .obj_addr,  .obj_ack,  .obj_q,
        .ce_pix, .red(r), .green(g), .blue(b),
        .hsync(hs), .vsync(vs), .hblank(hb), .vblank, .de, .vcnt,
        .pix_index, .tile_cycles, .obj_cycles, .line_overrun
    );

    wire _unused = &{1'b0, r, g, b, hs, vs, hb, 1'b0};
endmodule

`default_nettype wire
