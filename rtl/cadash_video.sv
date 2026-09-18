//------------------------------------------------------------------------------
// Cadash's video: TC0100SCN, PC090OJ and TC0110PCR, with the RAM they own.
//
// Every RAM here is block RAM (docs/core-design.md section 3), so the line
// renderers see a fixed one-clock latency and their budget is deterministic.
// Only the graphics ROMs live in SDRAM, and both renderers read them a row at
// a time through their own ports.
//
// Line N+1 is rendered into one line buffer while line N is read out of the
// other.  A line buffer entry is {claimed, text, index}: the tilemap renderer
// writes the index and the text bit, and the sprite renderer does a read,
// modify and write against both -- see rtl/sprite_line.sv for why a sprite
// claims a pixel even when it cannot draw it.
//------------------------------------------------------------------------------
`default_nettype none

module cadash_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        pix_sync,       // pins the dot divider to the video clock

    // ---------------- CPU side ----------------
    // A region is selected for one clock; a read answers on the next.
    input  logic        vram_cs,        // C00000-C0FFFF, TC0100SCN RAM
    input  logic        ctrl_cs,        // C20000-C2000F, TC0100SCN control
    input  logic        spr_cs,         // B00000-B03FFF, PC090OJ RAM
    input  logic        pal_cs,         // A00000-A0000F, TC0110PCR
    input  logic        sprctl_cs,      // 080000-080003, sprite control
    input  logic [14:0] cpu_addr,       // word address inside the region
    input  logic [15:0] cpu_din,
    input  logic  [1:0] cpu_ds,         // {upper, lower} data strobe
    input  logic        cpu_we,
    output logic [15:0] cpu_dout,

    // ---------------- graphics ROM ----------------
    output logic        tile_req,
    output logic [16:0] tile_addr,      // 32-bit words: {tile[13:0], row[2:0]}
    input  logic        tile_ack,
    input  logic [31:0] tile_q,

    output logic        obj_req,
    output logic [15:0] obj_addr,       // 64-bit words: {tile[11:0], row[3:0]}
    input  logic        obj_ack,
    input  logic [63:0] obj_q,

    // ---------------- video out ----------------
    output logic        ce_pix,
    output logic  [7:0] red, green, blue,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic  [8:0] vcnt,

    output logic [11:0] pix_index,      // the palette index behind the colour

    // ---------------- diagnostics ----------------
    output logic [15:0] tile_cycles,    // clocks the last line's tilemaps took
    output logic [15:0] obj_cycles,     // and its sprites
    output logic  [7:0] line_overrun    // lines that did not finish in time
);
    // ------------------------------------------------------------- timing
    logic [8:0] hcnt;
    logic       line_start, frame_start;
    logic       hs_t, vs_t, hb_t, vb_t, de_t;

    video_timing u_timing (
        .clk, .reset, .pix_sync, .ce_pix, .hcnt, .vcnt,
        .hsync(hs_t), .vsync(vs_t), .hblank(hb_t), .vblank(vb_t), .de(de_t),
        .line_start, .frame_start
    );

    // ------------------------------------------------- TC0100SCN control
    logic [15:0] ctrl [8];
    wire         ctrl_wr = ctrl_cs && cpu_we;

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 8; i++) ctrl[i] <= '0;
        end else if (ctrl_wr) begin
            if (cpu_ds[1]) ctrl[cpu_addr[2:0]][15:8] <= cpu_din[15:8];
            if (cpu_ds[0]) ctrl[cpu_addr[2:0]][7:0]  <= cpu_din[7:0];
        end
    end

    // -------------------------------------------------- the CPU's write port
    // The 64 KB of tilemap RAM needs a read port for the CPU and another for
    // the renderer, which is one more than an M10K has, so Quartus builds it
    // twice and every write goes to both copies.  That makes the write signals
    // the widest fan-out in the core, and taking them straight from the
    // address decode was the one path in the whole design that missed timing.
    // Registering them here gives the fitter a fabric register it can
    // duplicate near each half of the array; the extra clock costs nothing,
    // because a 68000 bus cycle is twenty-four of them.
    (* maxfan = 16 *) logic        wr_q;
    (* maxfan = 16 *) logic [14:0] wa_q;
                      logic [15:0] wd_q;
    (* maxfan = 16 *) logic  [1:0] wb_q;
    logic sp_wr_q, pl_wr_q;

    always_ff @(posedge clk) begin
        wr_q    <= vram_cs && cpu_we;
        sp_wr_q <= spr_cs  && cpu_we;
        pl_wr_q <= pal_cs  && cpu_we && (cpu_addr[1:0] == 2'd1);
        wa_q    <= cpu_addr;
        wd_q    <= cpu_din;
        wb_q    <= cpu_ds;
    end

    // ---------------------------------------------------------- TC0100SCN RAM
    // 32768 x 16, byte enables, one port for the CPU and one for the renderer.
    // Packed 2D so Quartus infers byte enables rather than a wall of registers.
    logic [1:0][7:0] vram [0:32767];
    logic     [15:0] vram_cpu_q, vram_ren_q;
    logic     [14:0] tm_vaddr;

    always_ff @(posedge clk) begin
        if (wr_q) begin
            if (wb_q[1]) vram[wa_q][1] <= wd_q[15:8];
            if (wb_q[0]) vram[wa_q][0] <= wd_q[7:0];
        end
        vram_cpu_q <= vram[cpu_addr];
        vram_ren_q <= vram[tm_vaddr];
    end

    // ---------------------------------------------------------- PC090OJ RAM
    // 8192 x 16 on the CPU side, of which the first 1024 words are the active
    // table; the chip copies those into its own buffer at the start of vblank
    // and draws from the copy.
    logic [1:0][7:0] sram [0:8191];
    logic     [15:0] sram_cpu_q, sram_copy_q;
    logic     [12:0] copy_addr;

    always_ff @(posedge clk) begin
        if (sp_wr_q) begin
            if (wb_q[1]) sram[wa_q[12:0]][1] <= wd_q[15:8];
            if (wb_q[0]) sram[wa_q[12:0]][0] <= wd_q[7:0];
        end
        sram_cpu_q  <= sram[cpu_addr[12:0]];
        sram_copy_q <= sram[copy_addr];
    end

    logic [15:0] sbuf [0:1023];
    logic  [9:0] tab_addr;
    logic [15:0] tab_q;
    logic        copy_run, copy_we;
    logic  [9:0] copy_idx, copy_widx;

    // The read address is combinational and the write address is one clock
    // behind it, because the sprite RAM answers a clock after it is addressed.
    always_ff @(posedge clk) begin
        if (copy_we) sbuf[copy_widx] <= sram_copy_q;
        tab_q <= sbuf[tab_addr];
    end

    // The flip register is sprite RAM word 0xDFF, and the chip latches it on
    // the write rather than at the buffer copy.
    logic [15:0] oj_ctrl;
    logic [15:0] spr_ctrl;

    always_ff @(posedge clk) begin
        if (reset) begin
            oj_ctrl  <= '0;
            spr_ctrl <= '0;
        end else begin
            if (spr_cs && cpu_we && cpu_addr[12:0] == 13'h0dff) oj_ctrl <= cpu_din;
            if (sprctl_cs && cpu_we && cpu_addr[0] == 1'b0)     spr_ctrl <= cpu_din;
        end
    end

    // --------------------------------------------------------- TC0110PCR
    // An address latch and a data port; 4096 entries of xBGR444 with red in
    // the low nibble (docs/hardware.md section 6).
    logic [15:0] pal [0:4095];
    logic [11:0] pal_addr;
    logic [15:0] pal_cpu_q, pal_out_q;
    logic [11:0] pal_rd_idx;

    always_ff @(posedge clk) begin
        if (reset) begin
            pal_addr <= '0;
        end else if (pal_cs && cpu_we && cpu_addr[1:0] == 2'd0) begin
            pal_addr <= cpu_din[11:0];
        end
        if (pl_wr_q) pal[pal_addr] <= wd_q;
        pal_cpu_q <= pal[pal_addr];
        pal_out_q <= pal[pal_rd_idx];
    end

    // ---------------------------------------------------- CPU read mux
    // Every region answers one clock after it is selected, so the selection is
    // held for that clock and the mux runs on the held copy.
    logic  [3:0] rd_sel;
    logic [15:0] ctrl_q;

    always_ff @(posedge clk) begin
        rd_sel <= {ctrl_cs, pal_cs, spr_cs, vram_cs};
        ctrl_q <= ctrl[cpu_addr[2:0]];
    end

    always_comb begin
        casez (rd_sel)
        4'b???1: cpu_dout = vram_cpu_q;
        4'b??10: cpu_dout = sram_cpu_q;
        4'b?100: cpu_dout = pal_cpu_q;
        4'b1000: cpu_dout = ctrl_q;
        default: cpu_dout = 16'hffff;
        endcase
    end

    // ------------------------------------------------------- line buffers
    // {claimed, text, index}
    logic [13:0] lb0 [0:319];
    logic [13:0] lb1 [0:319];
    logic [13:0] lb_ren_q;              // the renderer's read (sprite RMW)
    logic [13:0] lb_dsp_q;              // the display read

    logic        ren_buf;               // which buffer the renderer owns
    logic        lb_we;
    logic  [8:0] lb_x;
    logic [13:0] lb_d;
    logic  [8:0] lb_rd_x;
    logic  [8:0] dsp_x;

    wire [8:0] lb0_rd = ren_buf ? dsp_x : lb_rd_x;
    wire [8:0] lb1_rd = ren_buf ? lb_rd_x : dsp_x;
    logic [13:0] lb0_q, lb1_q;

    always_ff @(posedge clk) begin
        if (lb_we && !ren_buf) lb0[lb_x] <= lb_d;
        if (lb_we &&  ren_buf) lb1[lb_x] <= lb_d;
        lb0_q <= lb0[lb0_rd];
        lb1_q <= lb1[lb1_rd];
    end

    assign lb_ren_q = ren_buf ? lb1_q : lb0_q;
    assign lb_dsp_q = ren_buf ? lb0_q : lb1_q;

    // --------------------------------------------------------- renderers
    logic  [8:0] render_row;
    logic        rendering, ob_done;
    logic       tm_start, tm_busy, tm_we, tm_text;
    logic [8:0] tm_x;
    logic [11:0] tm_idx;

    // A line that does not finish in time is abandoned rather than allowed to
    // run into the next one: the picture loses whatever was left of it, which
    // is what running out of time looks like on hardware, and the renderer is
    // ready for the next line either way.  Without this a single overrun loses
    // the start pulse and the renderer never draws again.
    wire line_abort = line_start && rendering;

    tilemap_line u_tm (
        .clk, .reset, .drop(line_abort),
        .start(tm_start), .row(render_row), .busy(tm_busy),
        .ctrl0(ctrl[0]), .ctrl1(ctrl[1]), .ctrl2(ctrl[2]), .ctrl3(ctrl[3]),
        .ctrl4(ctrl[4]), .ctrl5(ctrl[5]), .ctrl6(ctrl[6]),
        .vram_addr(tm_vaddr), .vram_q(vram_ren_q),
        .gfx_req(tile_req), .gfx_addr(tile_addr),
        .gfx_ack(tile_ack), .gfx_q(tile_q),
        .lb_we(tm_we), .lb_x(tm_x), .lb_idx(tm_idx), .lb_text(tm_text),
        .cycles(tile_cycles)
    );

    logic        ob_start, ob_busy, ob_we;
    logic  [8:0] ob_x;
    logic [13:0] ob_d;

    sprite_line u_ob (
        .clk, .reset, .drop(line_abort),
        .start(ob_start), .row(render_row), .busy(ob_busy),
        .spr_ctrl(spr_ctrl), .oj_ctrl(oj_ctrl),
        .tab_addr(tab_addr), .tab_q(tab_q),
        .gfx_req(obj_req), .gfx_addr(obj_addr),
        .gfx_ack(obj_ack), .gfx_q(obj_q),
        .lb_rd_x(lb_rd_x), .lb_rd_q(lb_ren_q),
        .lb_we(ob_we), .lb_x(ob_x), .lb_d(ob_d),
        .cycles(obj_cycles)
    );

    assign lb_we = tm_busy ? tm_we : ob_we;
    assign lb_x  = tm_busy ? tm_x  : ob_x;
    assign lb_d  = tm_busy ? {1'b0, tm_text, tm_idx} : ob_d;

    // ------------------------------------------------------- the sequencer
    // line_start fires on the last dot of a line, before vcnt has moved, so
    // `cur_v` is the line about to begin and `next_v` the one after it.  The
    // renderer always works a line ahead of the display.
    wire [8:0] cur_v  = (vcnt  == 9'd261) ? 9'd0 : (vcnt  + 9'd1);
    wire [8:0] next_v = (cur_v == 9'd261) ? 9'd0 : (cur_v + 9'd1);

    always_ff @(posedge clk) begin
        tm_start <= 1'b0;
        ob_start <= 1'b0;
        copy_we  <= 1'b0;

        if (reset) begin
            rendering    <= 1'b0;
            ren_buf      <= 1'b0;
            copy_run     <= 1'b0;
            line_overrun <= '0;
        end else begin
            // one line of lead: render N+1 while N is displayed
            if (line_start) begin
                if (rendering && line_overrun != 8'hff)
                    line_overrun <= line_overrun + 8'd1;
                rendering <= 1'b0;
                // The buffers alternate every line whether or not there is
                // anything to draw into them, so the display always reads the
                // one the renderer is not holding.
                ren_buf <= next_v[0];
                if (next_v < 9'd240) begin
                    render_row <= next_v + 9'd16;   // MAME bitmap rows start at 16
                    tm_start   <= 1'b1;
                    rendering  <= 1'b1;
                end
                // the sprite table is copied at the start of vblank, which is
                // a line with no rendering to do
                if (cur_v == 9'd240) begin
                    copy_run <= 1'b1;
                    copy_idx <= '0;
                end
            end else if (rendering) begin
                if (!tm_busy && !tm_start && !ob_busy && !ob_start) begin
                    if (!ob_done) ob_start <= 1'b1;
                    else          rendering <= 1'b0;
                end
            end

            // 1024 words, one per clock
            if (copy_run) begin
                copy_we   <= 1'b1;
                copy_widx <= copy_idx;
                copy_idx  <= copy_idx + 10'd1;
                if (copy_idx == 10'd1023) copy_run <= 1'b0;
            end
        end
    end

    // `ob_done` marks that the sprite pass of this line has already run.
    always_ff @(posedge clk) begin
        if (tm_start)      ob_done <= 1'b0;
        else if (ob_start) ob_done <= 1'b1;
    end

    assign copy_addr = {3'd0, copy_idx};

    // ---------------------------------------------------------- read-out
    // Two dots of pipeline: address the line buffer, then the palette, then
    // emit.  The syncs travel with the pixel, so the whole picture simply sits
    // two dots later inside the blanking and the visible window still holds
    // exactly the 320 rendered pixels.
    logic  [4:0] sync_1, sync_2;
    logic [11:0] idx_1;

    always_ff @(posedge clk) begin
        if (ce_pix) begin
            dsp_x      <= hcnt;
            sync_1     <= {hs_t, vs_t, hb_t, vb_t, de_t};

            pal_rd_idx <= lb_dsp_q[11:0];
            idx_1      <= lb_dsp_q[11:0];
            sync_2     <= sync_1;

            {hsync, vsync, hblank, vblank, de} <= sync_2;
            pix_index <= idx_1;
            red   <= sync_2[0] ? {pal_out_q[3:0],  pal_out_q[3:0]}  : 8'd0;
            green <= sync_2[0] ? {pal_out_q[7:4],  pal_out_q[7:4]}  : 8'd0;
            blue  <= sync_2[0] ? {pal_out_q[11:8], pal_out_q[11:8]} : 8'd0;
        end
    end

    wire _unused = &{1'b0, frame_start, cpu_addr[14:13], lb_dsp_q[13:12],
                     pal_out_q[15:12], 1'b0};
endmodule

`default_nettype wire
