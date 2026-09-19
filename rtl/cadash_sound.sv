//------------------------------------------------------------------------------
// The sound board: the Z80, the YM2151 and the slave half of the PC060HA.
//
//   0000-3FFF  ROM, the first 16 KB of c21-08.38
//   4000-7FFF  ROM, one of four 16 KB banks
//   8000-8FFF  RAM, 4 KB
//   9000-9001  YM2151, 0 = address, 1 = data
//   A000       PC060HA slave port
//   A001       PC060HA slave comm
//
// The bank register is the YM2151 itself.  MAME wires the chip's port write
// handler to the bank (ref/mame/asuka.cpp:1275) and ymfm sends it `data >> 6`
// when register 0x1B is written, which is the chip's CT1 and CT2 output pins
// with CT2 the high bit.  So the window at 4000 follows {CT2, CT1} and there
// is no bank latch in the memory map at all.
//
// The YM2151's IRQ pin drives the Z80's INT; the PC060HA drives NMI when a
// command is waiting and can hold the Z80 in reset.
//------------------------------------------------------------------------------
`default_nettype none

module cadash_sound (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_cpu,        // 4 MHz
    input  logic        cen_ym,         // 4 MHz
    input  logic        cen_ym_p1,      // 2 MHz

    // sound ROM, 64 KB in SDRAM
    output logic        rom_req,
    output logic [15:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,

    // PC060HA, slave side
    output logic        ciu_port_wr,
    output logic        ciu_comm_wr,
    output logic        ciu_comm_rd,
    output logic  [7:0] ciu_din,
    input  logic  [7:0] ciu_dout,
    input  logic        ciu_nmi,
    input  logic        ciu_reset,

    output logic signed [15:0] sound
);
    // ---------------------------------------------------------------- CPU
    logic [15:0] a;
    logic  [7:0] di, dout;
    logic        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n, busak_n;
    logic        wait_n;
    logic        z80_rst_n;
    logic        ym_irq_n;
    logic        ct1, ct2;

    assign z80_rst_n = ~(rst | ciu_reset);

    tv80s_cen z80 (
        .reset_n(z80_rst_n), .clk(clk), .cen(cen_cpu),
        .wait_n(wait_n), .int_n(ym_irq_n), .nmi_n(~ciu_nmi), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n),
        .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
        .halt_n(halt_n), .busak_n(busak_n),
        .A(a), .di(di), .dout(dout)
    );

    wire mem    = ~mreq_n & rfsh_n;
    wire mem_rd = mem & ~rd_n;
    wire mem_wr = mem & ~wr_n;

    // A Z80 cycle spans several clock enables, so anything with a side effect
    // -- a YM2151 register write, a PC060HA access that advances its mode --
    // is driven from a one-shot at the start of the access rather than from
    // the enable itself.
    logic acc_d;
    always_ff @(posedge clk) acc_d <= mem_rd | mem_wr;
    wire  acc_first = (mem_rd | mem_wr) & ~acc_d;

    wire sel_rom  = mem && !a[15];                             // 0000-7FFF
    wire sel_ram  = mem && (a[15:12] == 4'h8);                 // 8000-8FFF
    wire sel_ym   = mem && (a[15:12] == 4'h9) && (a[11:1] == 11'd0);
    wire sel_ciu  = mem && (a[15:12] == 4'hA) && (a[11:1] == 11'd0);

    // ------------------------------------------------------------ work RAM
    (* ramstyle = "M10K" *) logic [7:0] ram [0:4095];
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (sel_ram && mem_wr && acc_first) ram[a[11:0]] <= dout;
        ram_q <= ram[a[11:0]];
    end

    // ----------------------------------------------------- banked ROM cache
    // Direct mapped, 1024 bytes over the whole 64 KB.  The ROM is read-only,
    // so an entry can never go stale.
    wire [1:0] bank = {ct2, ct1};
    wire [15:0] rom_a = a[14] ? {bank, a[13:0]} : {2'b00, a[13:0]};

    localparam int CLINES = 1024;
    (* ramstyle = "M10K" *) logic [7:0] crom_data [0:CLINES-1];
    (* ramstyle = "M10K" *) logic [5:0] crom_tag  [0:CLINES-1];
    // Packed, and cleared as one assignment below.  A non-blocking write
    // to an unpacked array inside a for loop is rejected by the older
    // lint tool CI installs (BLKLOOPINIT), and this is the same flops.
    logic [CLINES-1:0] crom_valid;

    wire [9:0] cidx = rom_a[9:0];
    wire [5:0] ctag = rom_a[15:10];
    logic [7:0] cdata_q;
    logic [5:0] ctag_q;
    logic       cvalid_q;
    always_ff @(posedge clk) begin
        cdata_q  <= crom_data[cidx];
        ctag_q   <= crom_tag[cidx];
        cvalid_q <= crom_valid[cidx];
    end
    wire cache_hit = cvalid_q && (ctag_q == ctag);

    typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FETCH, R_DONE } rstate_t;
    rstate_t rstate;
    logic [7:0] rom_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate  <= R_IDLE;
            rom_req <= 1'b0;
            crom_valid <= '0;
        end else begin
            case (rstate)
                R_IDLE: if (sel_rom && mem_rd) rstate <= R_LOOK;
                R_LOOK: begin
                    if (cache_hit) begin
                        rom_data <= cdata_q;
                        rstate   <= R_DONE;
                    end else begin
                        rom_addr <= rom_a;
                        rom_req  <= 1'b1;
                        rstate   <= R_FETCH;
                    end
                end
                R_FETCH: if (rom_ack) begin
                    rom_req  <= 1'b0;
                    rom_data <= rom_q;
                    crom_data[cidx]  <= rom_q;
                    crom_tag[cidx]   <= ctag;
                    crom_valid[cidx] <= 1'b1;
                    rstate   <= R_DONE;
                end
                R_DONE: if (!(sel_rom && mem_rd)) rstate <= R_IDLE;
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // The Z80 waits only for a ROM read that is not yet answered.
    assign wait_n = ~(sel_rom && mem_rd && rstate != R_DONE);

    // ----------------------------------------------------------- YM2151
    // jt51 only samples its bus on cen_p1, so a write is latched here and held
    // until the chip has had one; the real part latches asynchronously on /CS
    // and /WR and has no such hazard.
    logic       ym_pend;
    logic       ym_a0_l;
    logic [7:0] ym_din_l;
    logic [7:0] ym_dout;
    logic signed [15:0] ym_left, ym_right;

    always_ff @(posedge clk) begin
        if (rst) begin
            ym_pend <= 1'b0;
        end else begin
            if (sel_ym && mem_wr && acc_first) begin
                ym_pend  <= 1'b1;
                ym_a0_l  <= a[0];
                ym_din_l <= dout;
            end else if (ym_pend && cen_ym_p1) begin
                ym_pend <= 1'b0;
            end
        end
    end

    jt51 ym (
        .rst(rst), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym_p1),
        .cs_n(~(ym_pend | (sel_ym & mem_rd))),
        .wr_n(~ym_pend),
        .a0(ym_pend ? ym_a0_l : a[0]),
        .din(ym_din_l), .dout(ym_dout),
        .ct1(ct1), .ct2(ct2), .irq_n(ym_irq_n), .sample(),
        .left(ym_left), .right(ym_right), .xleft(), .xright()
    );

    // MAME routes both channels to the one speaker at half each.
    wire signed [16:0] ym_mix = {ym_left[15], ym_left} + {ym_right[15], ym_right};
    always_ff @(posedge clk) sound <= ym_mix[16:1];

    // ----------------------------------------------------------- PC060HA
    // Reading the CIU advances its mode, so the byte has to be captured on the
    // first clock of the access -- before the strobe moves the mode on -- and
    // that capture is what the Z80 is given.  Handing it the live output
    // instead gives it the *next* slot's nibble, because the Z80 samples its
    // data bus at the end of the cycle, a couple of dozen clocks later.
    logic [7:0] ciu_q;
    always_ff @(posedge clk) if (sel_ciu && acc_first) ciu_q <= ciu_dout;

    assign ciu_din     = dout;
    assign ciu_port_wr = sel_ciu && mem_wr && acc_first && !a[0];
    assign ciu_comm_wr = sel_ciu && mem_wr && acc_first &&  a[0];
    assign ciu_comm_rd = sel_ciu && mem_rd && acc_first &&  a[0];

    // --------------------------------------------------------- read mux
    always_comb begin
        if      (sel_rom) di = rom_data;
        else if (sel_ram) di = ram_q;
        else if (sel_ym)  di = ym_dout;
        else if (sel_ciu) di = ciu_q;
        else              di = 8'hff;
    end

    wire _unused = &{1'b0, m1_n, halt_n, busak_n, iorq_n, a[11:1], 1'b0};
endmodule

`default_nettype wire
