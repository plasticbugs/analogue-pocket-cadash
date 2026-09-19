// Bench wrapper for target/pocket/cadash_mem.sv: the Pocket memory subsystem
// with a behavioural SDRAM chip behind it.  The C++ side (sim/tb_mem.cpp)
// pushes the real ROM image in through the download port at the APF loader's
// rate and reads every word of every region back through the core ports.
//
// This is the gate the core shipped without: tb_system_top.sv answers both
// CPUs from plain arrays, so nothing in the simulation had ever exercised the
// controller, its arbiter, or the download path that fills it.
`default_nettype none
module tb_mem_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        rd_late, burst_slow,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    input  logic        mrom_req, input  logic [18:1] mrom_addr,
    output logic        mrom_ack, output logic [15:0] mrom_q,
    input  logic        srom_req, input  logic [15:0] srom_addr,
    output logic        srom_ack, output logic  [7:0] srom_q,
    input  logic        tile_req, input  logic [16:0] tile_addr,
    output logic        tile_ack, output logic [31:0] tile_q,
    input  logic        obj_req,  input  logic [15:0] obj_addr,
    output logic        obj_ack,  output logic [63:0] obj_q
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;

    cadash_mem dut (
        .clk(clk), .clk_sdram(clk), .init(init), .ready(ready),
        .rd_late(rd_late), .burst_slow(burst_slow),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .obj_req(obj_req), .obj_addr(obj_addr), .obj_ack(obj_ack), .obj_q(obj_q),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
    );

    sdram_model #(.AW(22)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
