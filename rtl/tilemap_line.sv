//------------------------------------------------------------------------------
// TC0100SCN line renderer: the three tilemap layers, one scanline at a time.
//
// This is a direct transcription of tools/render_model.py, which is
// pixel-identical to MAME over the state set in ref/states.  For MAME bitmap
// row y (16..255) and screen column x (0..319):
//
//     source x = (x + 17 - ctrl_x - rowscroll[y - 8]) & 0x1FF
//     source y = (y -  8 - ctrl_y) & 0x1FF
//
// and BG1 additionally shifts the sampled row by its column-scroll word,
// indexed by source x / 8, which is constant across one 8-pixel group:
//
//     source y = (source y - colscroll[source x / 8]) & 0x1FF
//
// The 17 and the 8 are the chip's offsets as MAME applies them for
// set_offsets(1, 0).  Both subtractions really are subtractions: the scroll
// registers are negated once in the chip and once more in MAME's tilemap
// layer, and getting that wrong is invisible whenever the register happens to
// be a multiple of 512 -- see docs/hardware.md section 9.
//
// Three passes per line, in the order the priority rule needs: the bottom
// background opaquely (which also initialises the line buffer), then the top
// background, then the text layer, which marks the pixels it wrote so the
// sprite renderer can stay underneath them.
//
// Fetching a group and writing one run side by side with a one-group slot
// between them, so a group costs the larger of its eight pixels and its fetch
// rather than the sum.
//------------------------------------------------------------------------------
`default_nettype none

module tilemap_line (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // render `row` into the line buffer
    input  logic        drop,          // give up: the line ran out of time
    input  logic  [8:0] row,            // MAME bitmap row, 16..255
    output logic        busy,

    input  logic [15:0] ctrl0, ctrl1, ctrl2, ctrl3, ctrl4, ctrl5, ctrl6,

    // VRAM, one word per clock, one clock of latency
    output logic [14:0] vram_addr,
    input  logic [15:0] vram_q,

    // tile graphics: one 32-bit word is one 8-pixel row
    output logic        gfx_req,
    output logic [16:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [31:0] gfx_q,

    // line buffer
    output logic        lb_we,
    output logic  [8:0] lb_x,
    output logic [11:0] lb_idx,
    output logic        lb_text,

    output logic [15:0] cycles          // clocks the line took, for the budget
);
    // VRAM word bases (docs/hardware.md section 7.1, byte addresses halved)
    localparam logic [14:0] BG0_MAP   = 15'h0000;
    localparam logic [14:0] TX_MAP    = 15'h2000;
    localparam logic [14:0] TX_GFX    = 15'h3000;
    localparam logic [14:0] BG1_MAP   = 15'h4000;
    localparam logic [14:0] BG0_ROWSC = 15'h6000;
    localparam logic [14:0] BG1_ROWSC = 15'h6200;
    localparam logic [14:0] COLSC     = 15'h7000;

    wire bg0_off = ctrl6[0];
    wire bg1_off = ctrl6[1];
    wire tx_off  = ctrl6[2];
    wire bottom  = ctrl6[3];            // 1 = BG1 underneath, which Cadash always sets

    // ------------------------------------------------------------ fetcher
    typedef enum logic [3:0] {
        G_IDLE, G_PASS, G_ROWSC, G_ROWSC_W,
        G_GROUP, G_COLSC, G_COLSC_W, G_ATTR, G_ATTR_W, G_CODE, G_FETCH,
        G_HAND, G_ENDPASS
    } gstate_t;

    gstate_t     gs;
    logic  [1:0] pass;                  // 0 bottom bg, 1 top bg, 2 text
    logic        layer_bg1, is_text, is_opaque, is_fill;
    logic  [8:0] sx;                    // source x of the next group
    logic  [8:0] sy;                    // source y for this line, before colscroll
    logic  [8:0] fpx;                   // screen x the next group starts at
    logic  [8:0] grp_row;               // source y for this group
    logic [15:0] f_attr;
    logic [31:0] f_data;

    // the one-group slot between fetcher and blitter
    logic        slot_full;
    logic [15:0] p_attr;
    logic [31:0] p_data;
    logic  [2:0] p_k0;
    logic  [8:0] p_px;
    logic        p_text, p_opaque;

    wire [15:0] scroll_x = layer_bg1 ? ctrl1 : ctrl0;
    wire [15:0] scroll_y = layer_bg1 ? ctrl4 : ctrl3;

    // Which pass is about to run, and whether the game has disabled it.
    wire        want_bg1 = (pass == 2'd0) ? bottom : ~bottom;
    wire        bg_off   = want_bg1 ? bg1_off : bg0_off;
    wire        pass_off = (pass == 2'd2) ? tx_off : bg_off;

    // The group's source row, always out of a register.
    //
    // This used to read (gs == G_COLSC) ? (sy - vram_q[8:0]) : grp_row, so
    // that BG1's attribute address was formed from the column-scroll word in
    // the same clock it arrived and the group cost one clock less.  That put a
    // VRAM read, the output mux across 64 M10Ks, this subtract and a VRAM
    // address register all in one clock: 9.303 ns of a 10.416 ns period, and
    // the longest path in the core by some way.  G_COLSC_W buys the clock back
    // and the line budget has thousands to spare.
    wire  [8:0] row_sel  = grp_row;
    wire  [5:0] tile_y   = row_sel[8:3];
    wire  [2:0] fine_y   = row_sel[2:0];
    wire  [5:0] tile_x   = sx[8:3];
    // The backgrounds take two words per tile, attribute then code; the text
    // layer packs both into one.
    wire [14:0] map_addr = is_text
        ? (TX_MAP + {3'd0, tile_y, tile_x})
        : ((layer_bg1 ? BG1_MAP : BG0_MAP) + {2'd0, tile_y, tile_x, 1'b0});

    // The text layer's characters live in VRAM, two bitplanes in one word per
    // row.  The character number and its flip bit come from f_attr, which
    // G_ATTR has registered by the time G_ATTR_W presents this address -- the
    // same read-to-address loop as row_sel above, for the same reason.
    wire  [2:0] tx_y     = f_attr[15] ? (3'd7 - fine_y) : fine_y;
    wire [14:0] tx_addr  = TX_GFX + {4'd0, f_attr[7:0], tx_y};

    // Background tiles live in the graphics ROM, one 32-bit word per row.
    wire  [2:0] bg_y     = f_attr[15] ? (3'd7 - fine_y) : fine_y;

    wire  [8:0] grp_end  = fpx + 9'(8 - {6'd0, sx[2:0]});   // first x after this group
    wire        hand_ok  = (gs == G_HAND) && !slot_full;

    always_ff @(posedge clk) begin
        if (reset || drop) begin
            gs      <= G_IDLE;
            gfx_req <= 1'b0;
        end else begin
            case (gs)
            G_IDLE: if (start) begin
                pass <= 2'd0;
                gs   <= G_PASS;
            end

            G_PASS: begin
                layer_bg1 <= want_bg1;
                is_text   <= (pass == 2'd2);
                is_opaque <= (pass == 2'd0);
                is_fill   <= 1'b0;
                fpx       <= '0;
                if (pass_off) begin
                    // MAME clears the bitmap before drawing anything, so a
                    // disabled bottom layer still leaves the line at index 0;
                    // a disabled layer above it simply draws nothing.  The
                    // clear is published as groups of an all-zero tile, which
                    // needs no memory at all.
                    if (pass == 2'd0) begin
                        is_fill <= 1'b1;
                        sx      <= '0;
                        f_attr  <= '0;
                        f_data  <= '0;
                        gs      <= G_HAND;
                    end else begin
                        gs <= G_ENDPASS;
                    end
                end else if (pass == 2'd2) begin
                    sx      <= 9'd17 - ctrl2[8:0];
                    sy      <= row - 9'd8 - ctrl5[8:0];
                    grp_row <= row - 9'd8 - ctrl5[8:0];
                    gs      <= G_GROUP;
                end else begin
                    gs <= G_ROWSC;
                end
            end

            G_ROWSC: gs <= G_ROWSC_W;

            G_ROWSC_W: begin
                sx      <= 9'd17 - scroll_x[8:0] - vram_q[8:0];
                sy      <= row - 9'd8 - scroll_y[8:0];
                grp_row <= row - 9'd8 - scroll_y[8:0];
                gs      <= G_GROUP;
            end

            // BG1 reads its column-scroll word first; everything else goes
            // straight to the attribute word.
            G_GROUP: gs <= (!is_text && layer_bg1) ? G_COLSC : G_ATTR;

            G_COLSC: begin
                grp_row <= sy - vram_q[8:0];
                gs      <= G_COLSC_W;
            end

            // grp_row is in its register now, so map_addr is safe to present.
            G_COLSC_W: gs <= G_ATTR;

            G_ATTR: begin
                f_attr <= vram_q;
                gs     <= is_text ? G_ATTR_W : G_CODE;
            end

            // Likewise for tx_addr, which needs f_attr.
            G_ATTR_W: gs <= G_CODE;

            G_CODE: begin
                if (is_text) begin
                    f_data <= {vram_q, 16'd0};  // the character row arrived here
                    gs     <= G_HAND;
                end else begin
                    gfx_req  <= 1'b1;
                    gfx_addr <= {vram_q[13:0], bg_y};
                    gs       <= G_FETCH;
                end
            end

            G_FETCH: begin
                if (gfx_ack) begin
                    gfx_req <= 1'b0;
                    f_data  <= gfx_q;
                    gs      <= G_HAND;
                end
            end

            // Hand the group over as soon as the blitter has taken the last
            // one, and start on the next without waiting for it to be drawn.
            G_HAND: if (!slot_full) begin
                sx  <= sx + 9'(8 - {6'd0, sx[2:0]});
                fpx <= grp_end;
                if (grp_end >= 9'd320) gs <= G_ENDPASS;
                else if (is_fill)      gs <= G_HAND;
                else                   gs <= G_GROUP;
            end

            G_ENDPASS: begin
                if (pass == 2'd2) begin
                    gs <= G_IDLE;
                end else begin
                    pass <= pass + 2'd1;
                    gs   <= G_PASS;
                end
            end

            default: gs <= G_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ blitter
    // The blitter takes its own copy of the group.  The slot is free again the
    // moment it does, so the fetcher starts on the next group immediately and
    // would otherwise overwrite the data still being drawn.
    logic        running;
    logic  [2:0] k;
    logic  [8:0] bpx;
    logic [15:0] b_attr;
    logic [31:0] b_data;
    logic        b_text, b_opaque;

    wire  [2:0] kk    = b_attr[14] ? (3'd7 - k) : k;
    wire  [4:0] nib   = 5'd31 - {kk, 2'b00};
    wire  [4:0] bit0  = 5'd31 - {2'b00, kk};
    wire  [4:0] bit1  = 5'd23 - {2'b00, kk};
    wire  [3:0] pen   = b_text ? {2'd0, b_data[bit0], b_data[bit1]}
                               : b_data[nib -: 4];
    wire [11:0] index = b_text ? {2'd0, b_attr[13:8], pen} : {b_attr[7:0], pen};

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;

        if (reset || drop) begin
            running   <= 1'b0;
            slot_full <= 1'b0;
        end else begin
            if (hand_ok) begin
                p_attr    <= f_attr;
                p_data    <= f_data;
                p_k0      <= sx[2:0];
                p_px      <= fpx;
                p_text    <= is_text;
                p_opaque  <= is_opaque;
                slot_full <= 1'b1;
            end

            if (!running) begin
                if (slot_full && !hand_ok) begin
                    b_attr    <= p_attr;
                    b_data    <= p_data;
                    b_text    <= p_text;
                    b_opaque  <= p_opaque;
                    k         <= p_k0;
                    bpx       <= p_px;
                    running   <= 1'b1;
                    slot_full <= 1'b0;
                end
            end else begin
                if (b_opaque || pen != 4'd0) begin
                    lb_we   <= 1'b1;
                    lb_x    <= bpx;
                    lb_idx  <= index;
                    lb_text <= b_text;
                end
                k   <= k + 3'd1;
                bpx <= bpx + 9'd1;
                if (k == 3'd7 || bpx == 9'd319) running <= 1'b0;
            end
        end
    end

    assign busy = (gs != G_IDLE) || slot_full || running || lb_we;

    always_ff @(posedge clk) begin
        if (reset)      cycles <= '0;
        else if (start) cycles <= '0;
        else if (busy)  cycles <= cycles + 16'd1;
    end

    // The VRAM address whose answer arrives next clock.
    always_comb begin
        case (gs)
        G_ROWSC:  vram_addr = (layer_bg1 ? BG1_ROWSC : BG0_ROWSC) + {6'd0, row - 9'd8};
        G_GROUP:  vram_addr = (!is_text && layer_bg1) ? (COLSC + {9'd0, sx[8:3]}) : map_addr;
        G_COLSC_W: vram_addr = map_addr;
        G_ATTR:   vram_addr = map_addr | 15'd1;      // backgrounds; text waits
        G_ATTR_W: vram_addr = tx_addr;
        default:  vram_addr = map_addr;
        endcase
    end

    wire _unused = &{1'b0, ctrl2[15:9], ctrl5[15:9],
                     scroll_x[15:9], scroll_y[15:9], 1'b0};
endmodule

`default_nettype wire
