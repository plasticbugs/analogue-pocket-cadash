//------------------------------------------------------------------------------
// Whole-machine bench: the entire core with the ROM image behind a model of
// the Pocket's SDRAM, so both CPUs run the real program.
//
// The four ROM ports share one latency setting, which is the number the video
// budget in docs/core-design.md is quoted against.
//------------------------------------------------------------------------------
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        reset,

    // loading: one word of the selected region per clock
    input  logic        ld_we,
    input  logic [17:0] ld_addr,
    input  logic [63:0] ld_data,
    input  logic  [1:0] ld_sel,         // 0 program, 1 sound, 2 tiles, 3 sprites

    input  logic  [5:0] rom_lat,

    input  logic  [7:0] dswa, dswb, in0, in1, in2,

    output logic        ce_pix,
    output logic [11:0] pix_index,
    output logic        de, vblank,
    output logic  [8:0] vcnt,
    output logic signed [15:0] sound,
    output logic        dbg_halted,
    output logic  [7:0] dbg_line_overrun,
    output logic [15:0] dbg_tile_cycles,
    output logic [15:0] dbg_obj_cycles
);
    logic [15:0] prog [0:262143];       // 512 KB as 16-bit words
    logic  [7:0] snd  [0:65535];
    logic [31:0] tile [0:131071];
    logic [63:0] obj  [0:65535];

    always_ff @(posedge clk) if (ld_we) begin
        case (ld_sel)
        2'd0: prog[ld_addr]         <= ld_data[15:0];
        2'd1: snd [ld_addr[15:0]]   <= ld_data[7:0];
        2'd2: tile[{1'b0, ld_addr}] <= ld_data[31:0];
        2'd3: obj [ld_addr[15:0]]   <= ld_data;
        default: ;
        endcase
    end

    // ------------------------------------------------- 68000 program port
    logic        mrom_req, mrom_ack;
    logic [18:1] mrom_addr;
    logic [15:0] mrom_q;
    logic  [5:0] mrom_cnt;
    always_ff @(posedge clk) begin
        mrom_ack <= 1'b0;
        if (!mrom_req) mrom_cnt <= '0;
        else if (!mrom_ack) begin
            if (mrom_cnt >= rom_lat) begin
                mrom_cnt <= '0; mrom_ack <= 1'b1; mrom_q <= prog[mrom_addr];
            end else mrom_cnt <= mrom_cnt + 6'd1;
        end
    end

    // --------------------------------------------------- Z80 program port
    logic        srom_req, srom_ack;
    logic [15:0] srom_addr;
    logic  [7:0] srom_q;
    logic  [5:0] srom_cnt;
    always_ff @(posedge clk) begin
        srom_ack <= 1'b0;
        if (!srom_req) srom_cnt <= '0;
        else if (!srom_ack) begin
            if (srom_cnt >= rom_lat) begin
                srom_cnt <= '0; srom_ack <= 1'b1; srom_q <= snd[srom_addr];
            end else srom_cnt <= srom_cnt + 6'd1;
        end
    end

    // --------------------------------------------------- tile graphics port
    logic        tile_req, tile_ack;
    logic [16:0] tile_addr;
    logic [31:0] tile_q;
    logic  [5:0] tile_cnt;
    always_ff @(posedge clk) begin
        tile_ack <= 1'b0;
        if (!tile_req) tile_cnt <= '0;
        else if (!tile_ack) begin
            if (tile_cnt >= rom_lat) begin
                tile_cnt <= '0; tile_ack <= 1'b1; tile_q <= tile[tile_addr];
            end else tile_cnt <= tile_cnt + 6'd1;
        end
    end

    // ------------------------------------------------- sprite graphics port
    logic        obj_req, obj_ack;
    logic [15:0] obj_addr;
    logic [63:0] obj_q;
    logic  [5:0] obj_cnt;
    always_ff @(posedge clk) begin
        obj_ack <= 1'b0;
        if (!obj_req) obj_cnt <= '0;
        else if (!obj_ack) begin
            if (obj_cnt >= rom_lat) begin
                obj_cnt <= '0; obj_ack <= 1'b1; obj_q <= obj[obj_addr];
            end else obj_cnt <= obj_cnt + 6'd1;
        end
    end

    // -------------------------------------------------------------- DUT
    logic [7:0] r, g, b;
    logic       hs, vs, hb;
    logic [3:0] coin;

    cadash_core u_core (
        .clk, .reset, .pix_sync(1'b0),
        .mrom_req, .mrom_addr, .mrom_ack, .mrom_q,
        .srom_req, .srom_addr, .srom_ack, .srom_q,
        .tile_req, .tile_addr, .tile_ack, .tile_q,
        .obj_req,  .obj_addr,  .obj_ack,  .obj_q,
        .dswa, .dswb, .in0, .in1, .in2, .coin_ctrl(coin),
        .ce_pix, .red(r), .green(g), .blue(b),
        .hsync(hs), .vsync(vs), .hblank(hb), .vblank, .de,
        .pix_index, .sound,
        .dbg_tile_cycles, .dbg_obj_cycles, .dbg_line_overrun, .dbg_halted
    );

    assign vcnt = u_core.vcnt;

    wire _unused = &{1'b0, r, g, b, hs, vs, hb, coin, 1'b0};
endmodule

`default_nettype wire
