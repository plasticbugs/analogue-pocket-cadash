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
    input  logic        pause,

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
    output logic [15:0] dbg_obj_cycles,

    // read-only window into the chip's RAM, so the bench can read the text
    // the boot self-test puts on the screen
    input  logic [14:0] probe_addr,
    output logic [15:0] probe_q,

    // activity counters, so a stuck machine can be told apart from a quiet one
    output logic [31:0] n_ciu_m, n_ciu_s, n_nmi, n_ym, n_z80_wr, n_irq,
    output logic [31:0] n_keyon, n_cen_ym, n_cen_p1,
    output logic [31:0] n_reg1b, n_reg08, n_reg14, n_reg_other, n_bank,
    output logic [31:0] n_ciu_s_wr, n_ciu_s_rd,
    output logic  [1:0] cur_bank,

    // the Z80's bus, so the bench can see where the sound driver is
    output logic [15:0] z80_addr,
    output logic        z80_m1,
    output logic [15:0] ym_last_l, ym_last_r,

    // the 68000's bus, so the bench can see where it is and what it moved
    output logic [23:1] m68k_addr,
    output logic        m68k_as, m68k_rw,
    output logic [15:0] m68k_dout, m68k_din,
    output logic  [1:0] m68k_ds,
    output logic        m68k_done
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
        .clk, .reset, .pause, .pix_sync(1'b0),
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

    assign vcnt    = u_core.vcnt;

    assign cur_bank = u_core.u_sound.bank;
    assign z80_addr = u_core.u_sound.a;
    // an instruction fetch: M1 with the memory request active
    assign z80_m1   = ~u_core.u_sound.m1_n & ~u_core.u_sound.mreq_n
                      & u_core.u_sound.rfsh_n & ~u_core.u_sound.rd_n;
    assign m68k_addr = u_core.u_main.cpu_addr;
    assign m68k_as   = ~u_core.u_main.as_n;
    assign m68k_rw   = ~u_core.u_main.rw_n;
    assign m68k_dout = u_core.u_main.cpu_dout;
    assign m68k_din  = u_core.u_main.din_r;
    assign m68k_ds   = u_core.u_main.ds;
    assign m68k_done = u_core.u_main.done;

    logic nmi_d, irq_d;
    logic [7:0] ym_reg;
    logic [1:0] bank_d;
    always_ff @(posedge clk) begin
        if (reset) begin
            n_ciu_m <= '0; n_ciu_s <= '0; n_nmi <= '0;
            n_ym <= '0; n_z80_wr <= '0; n_irq <= '0;
            n_keyon <= '0; n_cen_ym <= '0; n_cen_p1 <= '0;
            n_reg1b <= '0; n_reg08 <= '0; n_reg14 <= '0; n_reg_other <= '0;
            n_bank <= '0; bank_d <= '0;
            n_ciu_s_wr <= '0; n_ciu_s_rd <= '0;
        end else begin
            if (u_core.m_port_wr || u_core.m_comm_wr || u_core.m_comm_rd)
                n_ciu_m <= n_ciu_m + 32'd1;
            if (u_core.s_port_wr || u_core.s_comm_wr || u_core.s_comm_rd)
                n_ciu_s <= n_ciu_s + 32'd1;
            if (u_core.s_port_wr || u_core.s_comm_wr) n_ciu_s_wr <= n_ciu_s_wr + 32'd1;
            if (u_core.s_comm_rd)                     n_ciu_s_rd <= n_ciu_s_rd + 32'd1;
            nmi_d <= u_core.ciu_nmi;
            if (u_core.ciu_nmi && !nmi_d) n_nmi <= n_nmi + 32'd1;
            if (u_core.u_sound.sel_ym && u_core.u_sound.mem_wr
                && u_core.u_sound.acc_first) n_ym <= n_ym + 32'd1;
            if (u_core.u_sound.sel_ram && u_core.u_sound.mem_wr
                && u_core.u_sound.acc_first) n_z80_wr <= n_z80_wr + 32'd1;
            // what the sound driver actually asks the YM2151 for
            if (u_core.u_sound.sel_ym && u_core.u_sound.mem_wr
                && u_core.u_sound.acc_first) begin
                if (!u_core.u_sound.a[0]) begin
                    ym_reg <= u_core.u_sound.dout;
                    case (u_core.u_sound.dout)
                    8'h1b:   n_reg1b <= n_reg1b + 32'd1;
                    8'h08:   n_reg08 <= n_reg08 + 32'd1;
                    8'h14:   n_reg14 <= n_reg14 + 32'd1;
                    default: n_reg_other <= n_reg_other + 32'd1;
                    endcase
                end else if (ym_reg == 8'h08 && |u_core.u_sound.dout[6:3])
                    n_keyon <= n_keyon + 32'd1;
            end
            if (u_core.cen_ym)    n_cen_ym <= n_cen_ym + 32'd1;
            if (u_core.cen_ym_p1) n_cen_p1 <= n_cen_p1 + 32'd1;
            ym_last_l <= u_core.u_sound.ym_left;
            ym_last_r <= u_core.u_sound.ym_right;

            bank_d <= u_core.u_sound.bank;
            if (u_core.u_sound.bank != bank_d) n_bank <= n_bank + 32'd1;

            irq_d <= u_core.u_main.irq4;
            if (u_core.u_main.irq4 && !irq_d) n_irq <= n_irq + 32'd1;
        end
    end
    assign probe_q = {u_core.u_video.vram[probe_addr][1],
                      u_core.u_video.vram[probe_addr][0]};

    wire _unused = &{1'b0, r, g, b, hs, vs, hb, coin, 1'b0};
endmodule

`default_nettype wire
