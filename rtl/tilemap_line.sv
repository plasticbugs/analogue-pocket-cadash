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
//------------------------------------------------------------------------------
`default_nettype none

module tilemap_line (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // render `row` into the line buffer
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

    typedef enum logic [3:0] {
        S_IDLE, S_PASS, S_ROWSC, S_ROWSC_W,
        S_GROUP, S_COLSC, S_ATTR, S_CODE, S_FETCH, S_BLIT,
        S_FILL, S_DONE
    } state_t;

    state_t      state;
    logic  [1:0] pass;                  // 0 bottom bg, 1 top bg, 2 text
    logic        layer_bg1;             // which background this pass is drawing
    logic        is_text;
    logic        pass_opaque;

    logic  [8:0] sx;                    // source x of the next pixel
    logic  [8:0] sy;                    // source y for this line, before colscroll
    logic  [8:0] px;                    // screen x of the next pixel
    logic  [2:0] k;                     // pixel within the group
    logic [15:0] attr;
    logic [31:0] data;
    logic  [8:0] grp_row;               // source y for this group

    wire [15:0] scroll_x = layer_bg1 ? ctrl1 : ctrl0;
    wire [15:0] scroll_y = layer_bg1 ? ctrl4 : ctrl3;

    // Which pass is about to run, and whether the game has disabled it.
    wire        want_bg1 = (pass == 2'd0) ? bottom : ~bottom;
    wire        bg_off   = want_bg1 ? bg1_off : bg0_off;
    wire        pass_off = (pass == 2'd2) ? tx_off : bg_off;

    // The group's source row: registered from S_COLSC onwards, but needed one
    // clock earlier than that so BG1's attribute read can be issued as the
    // column-scroll word arrives.
    wire  [8:0] row_sel  = (state == S_COLSC) ? (sy - vram_q[8:0]) : grp_row;
    wire  [5:0] tile_y   = row_sel[8:3];
    wire  [2:0] fine_y   = row_sel[2:0];
    wire  [5:0] tile_x   = sx[8:3];
    // The backgrounds take two words per tile, attribute then code; the text
    // layer packs both into one.
    wire [14:0] map_addr = is_text
        ? (TX_MAP + {3'd0, tile_y, tile_x})
        : ((layer_bg1 ? BG1_MAP : BG0_MAP) + {2'd0, tile_y, tile_x, 1'b0});

    // The text layer's characters live in VRAM, two bitplanes in one word per
    // row; the attribute word is on the bus as this address is formed.
    wire  [2:0] tx_y     = vram_q[15] ? (3'd7 - fine_y) : fine_y;
    wire [14:0] tx_addr  = TX_GFX + {4'd0, vram_q[7:0], tx_y};

    // Background tiles live in the graphics ROM, one 32-bit word per row.
    wire  [2:0] bg_y     = attr[15] ? (3'd7 - fine_y) : fine_y;

    // The pen at position k of the group.  For the backgrounds the 32-bit word
    // is four packed bytes, two pixels each, left pixel in the high nibble;
    // for the text layer it is one VRAM word in the top half, plane 0 then
    // plane 1.
    wire  [2:0] kk       = attr[14] ? (3'd7 - k) : k;
    wire  [4:0] nib      = 5'd31 - {kk, 2'b00};
    wire  [4:0] bit0     = 5'd31 - {2'b00, kk};
    wire  [4:0] bit1     = 5'd23 - {2'b00, kk};
    wire  [3:0] bg_pen   = data[nib -: 4];
    wire  [3:0] tx_pen   = {2'd0, data[bit0], data[bit1]};
    wire  [3:0] pen      = is_text ? tx_pen : bg_pen;
    wire [11:0] index    = is_text ? {2'd0, attr[13:8], pen} : {attr[7:0], pen};

    assign busy = state != S_IDLE;

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;

        if (reset) begin
            state   <= S_IDLE;
            gfx_req <= 1'b0;
        end else begin
            if (state != S_IDLE) cycles <= cycles + 16'd1;

            case (state)
            // --------------------------------------------------------------
            S_IDLE: if (start) begin
                pass   <= 2'd0;
                cycles <= '0;
                state  <= S_PASS;
            end

            // --------------------------------------------------------------
            S_PASS: begin
                layer_bg1   <= want_bg1;
                is_text     <= (pass == 2'd2);
                pass_opaque <= (pass == 2'd0);
                px          <= '0;
                if (pass_off) begin
                    // MAME clears the bitmap before drawing anything, so a
                    // disabled bottom layer still leaves the line at index 0;
                    // a disabled layer above it simply draws nothing.
                    state <= (pass == 2'd0) ? S_FILL : S_DONE;
                end else if (pass == 2'd2) begin
                    sx      <= 9'd17 - ctrl2[8:0];
                    sy      <= row - 9'd8 - ctrl5[8:0];
                    grp_row <= row - 9'd8 - ctrl5[8:0];
                    state   <= S_GROUP;
                end else begin
                    state <= S_ROWSC;
                end
            end

            // ----------------------------------------------- row scroll
            S_ROWSC: state <= S_ROWSC_W;

            S_ROWSC_W: begin
                sx      <= 9'd17 - scroll_x[8:0] - vram_q[8:0];
                sy      <= row - 9'd8 - scroll_y[8:0];
                grp_row <= row - 9'd8 - scroll_y[8:0];
                state   <= S_GROUP;
            end

            // ----------------------------------------------- one group
            // BG1 reads its column-scroll word first; everything else goes
            // straight to the attribute word.
            S_GROUP: state <= (!is_text && layer_bg1) ? S_COLSC : S_ATTR;

            S_COLSC: begin
                grp_row <= sy - vram_q[8:0];
                state   <= S_ATTR;
            end

            S_ATTR: begin
                attr  <= vram_q;
                state <= S_CODE;
            end

            S_CODE: begin
                k <= sx[2:0];
                if (is_text) begin
                    // the character row arrived with this state
                    data  <= {vram_q, 16'd0};
                    state <= S_BLIT;
                end else begin
                    gfx_req  <= 1'b1;
                    gfx_addr <= {vram_q[13:0], bg_y};
                    state    <= S_FETCH;
                end
            end

            S_FETCH: if (gfx_ack) begin
                gfx_req <= 1'b0;
                data    <= gfx_q;
                state   <= S_BLIT;
            end

            // ----------------------------------------------- write the pixels
            S_BLIT: begin
                if (pass_opaque || pen != 4'd0) begin
                    lb_we   <= 1'b1;
                    lb_x    <= px;
                    lb_idx  <= index;
                    lb_text <= is_text;
                end
                px <= px + 9'd1;
                sx <= sx + 9'd1;
                k  <= k + 3'd1;
                if (px == 9'd319)     state <= S_DONE;
                else if (k == 3'd7)   state <= S_GROUP;
            end

            // ----------------------------------------------- blank line
            S_FILL: begin
                lb_we   <= 1'b1;
                lb_x    <= px;
                lb_idx  <= 12'd0;
                lb_text <= 1'b0;
                px      <= px + 9'd1;
                if (px == 9'd319) state <= S_DONE;
            end

            // --------------------------------------------------------------
            S_DONE: begin
                if (pass == 2'd2) begin
                    state <= S_IDLE;
                end else begin
                    pass  <= pass + 2'd1;
                    state <= S_PASS;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // The VRAM address whose answer arrives next clock.
    always_comb begin
        case (state)
        S_ROWSC:  vram_addr = (layer_bg1 ? BG1_ROWSC : BG0_ROWSC) + {6'd0, row - 9'd8};
        S_GROUP:  vram_addr = (!is_text && layer_bg1) ? (COLSC + {9'd0, sx[8:3]}) : map_addr;
        S_COLSC:  vram_addr = map_addr;
        S_ATTR:   vram_addr = is_text ? tx_addr : (map_addr | 15'd1);
        default:  vram_addr = map_addr;
        endcase
    end

    wire _unused = &{1'b0, ctrl2[15:9], ctrl5[15:9],
                     scroll_x[15:9], scroll_y[15:9], 1'b0};
endmodule

`default_nettype wire
