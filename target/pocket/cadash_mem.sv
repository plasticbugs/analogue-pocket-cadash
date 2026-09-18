//------------------------------------------------------------------------------
// The Pocket's SDRAM behind the core's four ROM ports.
//
//   0x000000  512 KB  68000 program      single words, cached in the core
//   0x040000   64 KB  Z80 program        single words, cached in the core
//   0x080000  512 KB  tile graphics      two words per 8-pixel row
//   0x0C0000  512 KB  sprite graphics    a four-word burst per 16-pixel row
//
// The bases are powers of two and every region fits inside its own, so the
// offsets go in with an OR and cost no adder.
//
// The sprite port uses the controller's burst channel because its four words
// are consecutive: one row activation covers all four, where four separate
// single-word reads would cost four.  The video budget in
// docs/core-design.md section 5 says the renderer tolerates about 25 clocks
// per graphics read, and that is the number this has to stay under while both
// CPUs are also asking for words.
//
// Client order is the priority order: the download runs only while the core is
// held in reset, then the two renderers, which have a deadline, then the two
// CPUs, which have caches and can wait.
//------------------------------------------------------------------------------
`default_nettype none

module cadash_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,

    // core ports
    input  logic        mrom_req,  input  logic [18:1] mrom_addr,
    output logic        mrom_ack,  output logic [15:0] mrom_q,

    input  logic        srom_req,  input  logic [15:0] srom_addr,
    output logic        srom_ack,  output logic  [7:0] srom_q,

    input  logic        tile_req,  input  logic [16:0] tile_addr,
    output logic        tile_ack,  output logic [31:0] tile_q,

    input  logic        obj_req,   input  logic [15:0] obj_addr,
    output logic        obj_ack,   output logic [63:0] obj_q,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK
);
    localparam logic [24:1] PROG_W = 24'h000000;
    localparam logic [24:1] SND_W  = 24'h040000;
    localparam logic [24:1] SCN_W  = 24'h080000;
    localparam logic [24:1] OBJ_W  = 24'h0C0000;
    // and where each starts in the image, as a byte offset
    localparam logic [24:0] SND_B  = 25'h080000;
    localparam logic [24:0] SCN_B  = 25'h090000;
    localparam logic [24:0] OBJ_B  = 25'h110000;

    // ------------------------------------------------------------ download
    // a byte at a time from the Pocket; a word is written when its odd byte
    // arrives, because the image is big-endian throughout
    logic [15:0] dl_word;
    logic        dl_pending;
    logic [24:1] dl_waddr;

    wire [24:1] dl_target =
        (dl_addr >= OBJ_B) ? (OBJ_W | 24'((dl_addr - OBJ_B) >> 1)) :
        (dl_addr >= SCN_B) ? (SCN_W | 24'((dl_addr - SCN_B) >> 1)) :
        (dl_addr >= SND_B) ? (SND_W | 24'((dl_addr - SND_B) >> 1)) :
                             (PROG_W | 24'(dl_addr >> 1));

    always_ff @(posedge clk) begin
        if (init) begin
            dl_pending <= 1'b0;
        end else if (dl_we) begin
            if (!dl_addr[0]) begin
                dl_word[15:8] <= dl_data;
            end else begin
                dl_word[7:0] <= dl_data;
                dl_waddr     <= dl_target;
                dl_pending   <= 1'b1;
            end
        end else if (dl_pending && dl_ack) begin
            dl_pending <= 1'b0;
        end
    end

    // ---------------------------------------------------- SDRAM clients
    localparam int NCLI = 4;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    // 0: the download
    wire dl_ack = c_ack[0];
    assign c_addr[0]  = dl_waddr;
    assign c_req[0]   = dl_pending;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dl_word;
    assign c_be[0]    = 2'b11;

    // 1: tile graphics, one 32-bit row as two consecutive words
    logic        t_phase;
    logic [15:0] t_hi;
    assign c_addr[1]  = SCN_W | {6'd0, tile_addr, t_phase};
    assign c_req[1]   = tile_req && !tile_ack;
    assign c_we[1]    = 1'b0;
    assign c_wdata[1] = 16'd0;
    assign c_be[1]    = 2'b11;

    always_ff @(posedge clk) begin
        tile_ack <= 1'b0;
        if (!tile_req) begin
            t_phase <= 1'b0;
        end else if (c_ack[1]) begin
            if (!t_phase) begin
                t_hi    <= rdata;
                t_phase <= 1'b1;
            end else begin
                tile_q   <= {t_hi, rdata};
                tile_ack <= 1'b1;
                t_phase  <= 1'b0;
            end
        end
    end

    // 2: the 68000's program
    assign c_addr[2]  = PROG_W | {6'd0, mrom_addr};
    assign c_req[2]   = mrom_req && !mrom_ack;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        mrom_ack <= c_ack[2];
        if (c_ack[2]) mrom_q <= rdata;
    end

    // 3: the Z80's program, two bytes to a word, high byte first
    assign c_addr[3]  = SND_W | {9'd0, srom_addr[15:1]};
    assign c_req[3]   = srom_req && !srom_ack;
    assign c_we[3]    = 1'b0;
    assign c_wdata[3] = 16'd0;
    assign c_be[3]    = 2'b11;
    logic srom_lo;
    always_ff @(posedge clk) begin
        srom_ack <= c_ack[3];
        if (c_req[3]) srom_lo <= srom_addr[0];
        if (c_ack[3]) srom_q <= srom_lo ? rdata[7:0] : rdata[15:8];
    end

    // ---------------------------------------- sprite graphics, burst of four
    logic       b_wr, b_done;
    logic [9:0] b_idx;
    logic [15:0] b_data;
    logic [63:0] obj_sr;

    always_ff @(posedge clk) begin
        obj_ack <= 1'b0;
        if (b_wr) obj_sr <= {obj_sr[47:0], b_data};
        if (b_done && obj_req) begin
            obj_q   <= obj_sr;
            obj_ack <= 1'b1;
        end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(OBJ_W | {6'd0, obj_addr, 2'b00}), .b_len(10'd4),
        .b_req(obj_req && !obj_ack), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx()
    );

    wire _unused = &{1'b0, b_idx, 1'b0};
endmodule

`default_nettype wire
