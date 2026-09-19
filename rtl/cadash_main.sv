//------------------------------------------------------------------------------
// The main board: the 68000, its address decode, main RAM and the link RAM.
//
//   000000-07FFFF  program ROM, 512 KB     through the cache below
//   080000-080003  PC090OJ sprite control, write only
//   0C0000-0C0003  PC060HA, odd byte
//   100000-107FFF  main RAM, 32 KB
//   800000-800FFF  link shared RAM: 2 KB of *bytes*, one per word address
//   900000-90000F  TC0220IOC, odd byte
//   A00000-A0000F  TC0110PCR
//   B00000-B03FFF  PC090OJ sprite RAM
//   C00000-C0FFFF  TC0100SCN RAM
//   C20000-C2000F  TC0100SCN control
//
// Interrupts.  cadash_state::interrupt (ref/mame/asuka.cpp:528) asserts IRQ4
// at the top of vblank and arms a timer for 500 68000 cycles which then
// asserts IRQ5.  Both are HOLD_LINE, so each stays pending until the CPU
// acknowledges that level; that is what the two flags here reproduce.  500
// cycles at 16 MHz is 3000 clocks of the 96 MHz system clock.
//
// The link RAM is the Z180's, and this core does not implement the Z180: the
// 68000 writes to it and reads back its own bytes, which is all a cabinet in
// Stand alone mode ever does with it.
//------------------------------------------------------------------------------
`default_nettype none

module cadash_main (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_phi1,
    input  logic        cen_phi2,

    // program ROM, 512 KB in SDRAM
    output logic        rom_req,
    output logic [18:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // the video chips
    output logic        vram_cs, ctrl_cs, spr_cs, pal_cs, sprctl_cs,
    output logic [14:0] vid_addr,
    output logic [15:0] vid_din,
    output logic  [1:0] vid_ds,
    output logic        vid_we,
    input  logic [15:0] vid_dout,
    input  logic        vblank_rise,

    // TC0220IOC
    output logic        ioc_wr,
    output logic  [2:0] ioc_addr,
    output logic  [7:0] ioc_din,
    input  logic  [7:0] ioc_dout,

    // PC060HA, master side
    output logic        ciu_port_wr,
    output logic        ciu_comm_wr,
    output logic        ciu_comm_rd,
    output logic  [7:0] ciu_din,
    input  logic  [7:0] ciu_dout,

    output logic        dbg_halted,
    output logic [23:1] dbg_addr
);
    // ---------------------------------------------------------------- CPU
    logic [23:1] cpu_addr;
    logic [15:0] cpu_dout, cpu_din;
    logic        as_n, uds_n, lds_n, rw_n, dtack_n, vpa_n;
    logic        fc0, fc1, fc2;
    logic        cpu_haltedn;
    logic        e_nc, vman_nc, bgn_nc, resetn_nc;
    logic  [2:0] ipl_n;

    fx68k cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(e_nc), .VMAn(vman_nc),
        .FC0(fc0), .FC1(fc1), .FC2(fc2),
        .BGn(bgn_nc), .oRESETn(resetn_nc), .oHALTEDn(cpu_haltedn),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(cpu_addr)
    );
    assign dbg_halted = ~cpu_haltedn;
    assign dbg_addr   = cpu_addr;

    // ----------------------------------------------------------- interrupts
    logic        irq4, irq5;
    logic [11:0] irq5_timer;            // 3000 clocks is 500 68000 cycles
    wire         iack       = fc0 & fc1 & fc2 & ~as_n;
    wire  [2:0]  iack_level = cpu_addr[3:1];
    wire  [2:0]  ipl        = irq5 ? 3'd5 : irq4 ? 3'd4 : 3'd0;
    assign ipl_n = ~ipl;
    assign vpa_n = ~iack;               // autovectored

    always_ff @(posedge clk) begin
        if (rst) begin
            irq4 <= 1'b0;
            irq5 <= 1'b0;
            irq5_timer <= '0;
        end else begin
            if (vblank_rise) begin
                irq4       <= 1'b1;
                irq5_timer <= 12'd3000;
            end else if (irq5_timer != 0) begin
                irq5_timer <= irq5_timer - 12'd1;
                if (irq5_timer == 12'd1) irq5 <= 1'b1;
            end
            if (iack && iack_level == 3'd4) irq4 <= 1'b0;
            if (iack && iack_level == 3'd5) irq5 <= 1'b0;
        end
    end

    // --------------------------------------------------------------- decode
    wire bus = ~as_n & (~uds_n | ~lds_n) & ~iack;
    wire wr  = ~rw_n;
    wire [1:0] ds = {~uds_n, ~lds_n};

    wire sel_rom    = bus & (cpu_addr[23:19] == 5'h00);              // 000000-07FFFF
    wire sel_sprctl = bus & (cpu_addr[23:2]  == 22'h020000);         // 080000-080003
    wire sel_ciu    = bus & (cpu_addr[23:2]  == 22'h030000);         // 0C0000-0C0003
    wire sel_ram    = bus & (cpu_addr[23:15] == 9'd32);               // 100000-107FFF
    wire sel_link   = bus & (cpu_addr[23:12] == 12'h800);            // 800000-800FFF
    wire sel_ioc    = bus & (cpu_addr[23:4]  == 20'h90000);          // 900000-90000F
    wire sel_pal    = bus & (cpu_addr[23:4]  == 20'hA0000);          // A00000-A0000F
    wire sel_spr    = bus & (cpu_addr[23:14] == 10'b1011_0000_00);   // B00000-B03FFF
    wire sel_vram   = bus & (cpu_addr[23:16] == 8'hC0);              // C00000-C0FFFF
    wire sel_ctrl   = bus & (cpu_addr[23:4]  == 20'hC2000);          // C20000-C2000F
    wire sel_none   = bus & ~(sel_rom | sel_sprctl | sel_ciu | sel_ram | sel_link
                            | sel_ioc | sel_pal | sel_spr | sel_vram | sel_ctrl);

    logic started, done;
    logic [15:0] din_r;
    wire  first = bus & ~started;

    // ------------------------------------------------------------ main RAM
    (* ramstyle = "M10K" *) logic [1:0][7:0] ram [0:16383];
    logic [15:0] ram_q;
    always_ff @(posedge clk) begin
        if (sel_ram && wr && first) begin
            if (ds[1]) ram[cpu_addr[14:1]][1] <= cpu_dout[15:8];
            if (ds[0]) ram[cpu_addr[14:1]][0] <= cpu_dout[7:0];
        end
        ram_q <= ram[cpu_addr[14:1]];
    end

    // ------------------------------------------------------------ link RAM
    // One byte per word address: the Z180 sees these as 8000-87FF.
    (* ramstyle = "M10K" *) logic [7:0] link [0:2047];
    logic [7:0] link_q;
    always_ff @(posedge clk) begin
        if (sel_link && wr && first) link[cpu_addr[11:1]] <= cpu_dout[7:0];
        link_q <= link[cpu_addr[11:1]];
    end

    // -------------------------------------------------- program ROM cache
    // Direct mapped, 2048 words.  The ROM never changes, so an entry can never
    // go stale and there is nothing to invalidate.
    localparam int CLINES = 2048;
    (* ramstyle = "M10K" *) logic [15:0] crom_data [0:CLINES-1];
    (* ramstyle = "M10K" *) logic  [7:0] crom_tag  [0:CLINES-1];
    // Packed, and cleared as one assignment below.  A non-blocking write
    // to an unpacked array inside a for loop is rejected by the older
    // lint tool CI installs (BLKLOOPINIT), and this is the same flops.
    logic [CLINES-1:0] crom_valid;

    wire [10:0] cidx = cpu_addr[11:1];
    wire  [7:0] ctag = cpu_addr[19:12];
    logic [15:0] cdata_q;
    logic  [7:0] ctag_q;
    logic        cvalid_q;
    always_ff @(posedge clk) begin
        cdata_q  <= crom_data[cidx];
        ctag_q   <= crom_tag[cidx];
        cvalid_q <= crom_valid[cidx];
    end
    wire cache_hit = cvalid_q && (ctag_q == ctag);

    typedef enum logic [1:0] { R_IDLE, R_LOOK, R_FETCH, R_DONE } rstate_t;
    rstate_t rstate;
    logic [15:0] rom_data;
    logic        rom_done;

    always_ff @(posedge clk) begin
        if (rst) begin
            rstate   <= R_IDLE;
            rom_req  <= 1'b0;
            rom_done <= 1'b0;
            crom_valid <= '0;
        end else begin
            rom_done <= 1'b0;
            case (rstate)
                R_IDLE: if (sel_rom && !done) rstate <= R_LOOK;
                R_LOOK: begin
                    if (cache_hit) begin
                        rom_data <= cdata_q;
                        rom_done <= 1'b1;
                        rstate   <= R_DONE;
                    end else begin
                        rom_addr <= cpu_addr[18:1];
                        rom_req  <= 1'b1;
                        rstate   <= R_FETCH;
                    end
                end
                R_FETCH: if (rom_ack) begin
                    rom_req  <= 1'b0;
                    rom_data <= rom_q;
                    rom_done <= 1'b1;
                    crom_data[cidx]  <= rom_q;
                    crom_tag[cidx]   <= ctag;
                    crom_valid[cidx] <= 1'b1;
                    rstate   <= R_DONE;
                end
                R_DONE: if (!bus) rstate <= R_IDLE;
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------- the video port
    assign vram_cs   = sel_vram;
    assign ctrl_cs   = sel_ctrl;
    assign spr_cs    = sel_spr;
    assign pal_cs    = sel_pal;
    assign sprctl_cs = sel_sprctl;
    assign vid_din   = cpu_dout;
    assign vid_ds    = ds;
    assign vid_we    = wr & first;
    always_comb begin
        unique case (1'b1)
        sel_vram: vid_addr = cpu_addr[15:1];
        sel_spr:  vid_addr = {2'd0, cpu_addr[13:1]};
        sel_pal:  vid_addr = {12'd0, cpu_addr[3:1]};
        sel_ctrl: vid_addr = {12'd0, cpu_addr[3:1]};
        default:  vid_addr = {14'd0, cpu_addr[1]};
        endcase
    end

    // ------------------------------------------- byte-wide chips, odd byte
    assign ioc_din  = cpu_dout[7:0];
    assign ioc_addr = cpu_addr[3:1];
    assign ioc_wr   = sel_ioc && first && wr;

    // A read of the CIU advances its mode, so the byte is captured on the
    // first clock of the bus cycle -- before the strobe moves the mode on --
    // and that capture is what the CPU is given.
    assign ciu_din     = cpu_dout[7:0];
    assign ciu_port_wr = sel_ciu && first && wr && !cpu_addr[1];
    assign ciu_comm_wr = sel_ciu && first && wr &&  cpu_addr[1];
    assign ciu_comm_rd = sel_ciu && first && !wr && cpu_addr[1];
    logic [7:0] ciu_q;
    always_ff @(posedge clk) if (sel_ciu && first) ciu_q <= ciu_dout;

    // ---------------------------------------------- bus cycle bookkeeping
    always_ff @(posedge clk) begin
        if (rst) begin
            started <= 1'b0;
            done    <= 1'b0;
            din_r   <= 16'd0;
        end else if (!bus) begin
            started <= 1'b0;
            done    <= 1'b0;
        end else begin
            started <= 1'b1;
            if (sel_rom && rom_done) begin done <= 1'b1; din_r <= rom_data; end
            if (started) begin
                if (sel_ram)  begin done <= 1'b1; din_r <= ram_q; end
                if (sel_link) begin done <= 1'b1; din_r <= {8'd0, link_q}; end
                if (sel_ioc)  begin done <= 1'b1; din_r <= {8'd0, ioc_dout}; end
                if (sel_ciu)  begin done <= 1'b1; din_r <= {8'd0, ciu_q}; end
                if (sel_vram || sel_spr || sel_pal || sel_ctrl)
                              begin done <= 1'b1; din_r <= vid_dout; end
                if (sel_sprctl || sel_none)
                              begin done <= 1'b1; din_r <= 16'hffff; end
            end
        end
    end

    assign cpu_din = din_r;
    assign dtack_n = ~done;

    wire _unused = &{1'b0, e_nc, vman_nc, bgn_nc, resetn_nc, cpu_addr[23:20],
                     cpu_dout[15:8], 1'b0};
endmodule

`default_nettype wire
