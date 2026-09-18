//------------------------------------------------------------------------------
// PC090OJ line renderer: 256 sprites of 16x16, one scanline at a time.
//
// A transcription of draw_sprites() in tools/render_model.py, which is
// pixel-identical to MAME.  Per entry, four words:
//
//     word 0   bit15 flip Y, bit14 flip X, bits 3..0 colour
//     word 1   Y, 9 bits
//     word 2   tile code, 13 bits
//     word 3   X, 9 bits
//
// Positions are signed: a value above 0x140 has 0x200 taken off it.  The
// chip's own flip bit (sprite RAM word 0xDFF, bit 0 clear) mirrors every
// sprite; Cadash sets it once at startup and never flips.  Cadash's offsets
// are (0, 8), added after the flip adjustment.
//
// Priority is the whole of what makes this chip interesting:
//
//   * the *first* sprite in the table wins, not the last
//   * a sprite claims a pixel even where the text layer stops it drawing, so
//     a sprite hidden under the text still hides the sprites behind it
//
// Both follow from MAME setting the top bit of the priority mask itself in
// gfx_element::prio_transpen; see docs/hardware.md section 7.3.
//
// Entries that miss the line cost two clocks, because only their Y word is
// read; the rest are read only once the line is known to be hit.
//------------------------------------------------------------------------------
`default_nettype none

module sprite_line (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,
    input  logic  [8:0] row,            // MAME bitmap row, 16..255
    output logic        busy,

    input  logic [15:0] spr_ctrl,       // the write-only register at 080000
    input  logic [15:0] oj_ctrl,        // buffered sprite RAM word 0xDFF

    // buffered sprite table, one word per clock, one clock of latency
    output logic  [9:0] tab_addr,
    input  logic [15:0] tab_q,

    // sprite graphics: one 64-bit word is one 16-pixel row
    output logic        gfx_req,
    output logic [15:0] gfx_addr,
    input  logic        gfx_ack,
    input  logic [63:0] gfx_q,

    // line buffer, read then modify then write
    output logic  [8:0] lb_rd_x,
    input  logic [13:0] lb_rd_q,        // {claimed, text, index}
    output logic        lb_we,
    output logic  [8:0] lb_x,
    output logic [13:0] lb_d,

    output logic [15:0] cycles
);
    typedef enum logic [3:0] {
        S_IDLE, S_Y, S_Y_W, S_ATTR, S_ATTR_W, S_CODE_W, S_X_W,
        S_FETCH, S_BLIT, S_NEXT
    } state_t;

    state_t       state;
    logic   [7:0] ent;                  // which of the 256 entries
    logic         flip_all;
    logic  [15:0] attr;
    logic  [63:0] data;
    logic signed [10:0] spr_y, spr_x;
    logic   [3:0] sub_y;                // row within the sprite
    logic   [4:0] k;                    // pixel within the sprite, 0..15

    // Colour bank: (sprite_ctrl & 0x3C) << 2, so the palette index is
    // {bank, entry colour, pen}.
    wire  [7:0] colbank = {spr_ctrl[5:2], 4'd0};

    // A word of Y or X, sign-extended the way the chip treats it.
    function automatic logic signed [10:0] coord(input logic [8:0] v);
        coord = (v > 9'd320) ? (11'(v) - 11'sd512) : 11'(v);
    endfunction

    wire signed [10:0] y_now = coord(tab_q[8:0]);
    wire signed [10:0] x_now = coord(tab_q[8:0]);
    // The flip adjustment is 320-x-16 and 256-y-16; the (0, 8) offsets go on
    // after it.
    wire signed [10:0] y_adj = (flip_all ? (11'sd240 - y_now) : y_now) + 11'sd8;
    wire signed [10:0] x_adj = (flip_all ? (11'sd304 - x_now) : x_now);

    wire signed [10:0] rel   = 11'(row) - y_adj;
    wire                on_line = (rel >= 11'sd0) && (rel <= 11'sd15);

    wire        flipy  = flip_all ^ attr[15];
    wire        flipx  = flip_all ^ attr[14];
    wire  [3:0] kk     = flipx ? (4'd15 - k[3:0]) : k[3:0];
    wire  [5:0] nib    = 6'd63 - {kk, 2'b00};
    wire  [3:0] pen    = data[nib -: 4];
    wire [11:0] index  = {colbank[7:4], attr[3:0], pen};

    wire signed [10:0] pix_x = spr_x + 11'(k);
    wire               pix_in = (pix_x >= 11'sd0) && (pix_x <= 11'sd319);

    // The read issued for pixel k is answered while k+1 is being issued, so
    // the write for pixel k happens one clock later still.
    logic        w_valid;
    logic  [8:0] w_x;
    logic [11:0] w_idx;

    assign busy    = state != S_IDLE;
    assign lb_rd_x = pix_x[8:0];

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;
        w_valid <= 1'b0;

        if (reset) begin
            state   <= S_IDLE;
            gfx_req <= 1'b0;
        end else begin
            if (state != S_IDLE) cycles <= cycles + 16'd1;

            // -------- the write half of the read-modify-write --------
            if (w_valid) begin
                if (!lb_rd_q[13]) begin
                    lb_we <= 1'b1;
                    lb_x  <= w_x;
                    // claim the pixel either way; only draw where the text
                    // layer did not
                    lb_d  <= {1'b1, lb_rd_q[12],
                              lb_rd_q[12] ? lb_rd_q[11:0] : w_idx};
                end
            end

            case (state)
            // --------------------------------------------------------------
            S_IDLE: if (start) begin
                ent      <= 8'd0;
                flip_all <= ~oj_ctrl[0];
                cycles   <= '0;
                state    <= S_Y;
            end

            // ------------------------------------------- is it on this line?
            S_Y:   state <= S_Y_W;

            // An entry that misses the line costs two clocks: the scan moves
            // straight on rather than going through S_NEXT.
            S_Y_W: begin
                spr_y <= y_adj;
                sub_y <= 4'(rel);
                if (on_line) begin
                    state <= S_ATTR;
                end else begin
                    ent   <= ent + 8'd1;
                    state <= (ent == 8'd255) ? S_IDLE : S_Y;
                end
            end

            // ------------------------------------------- the rest of the entry
            S_ATTR:   state <= S_ATTR_W;

            S_ATTR_W: begin
                attr  <= tab_q;
                state <= S_CODE_W;
            end

            S_CODE_W: begin
                gfx_req  <= 1'b1;
                gfx_addr <= {tab_q[11:0], flipy ? (4'd15 - sub_y) : sub_y};
                state    <= S_X_W;
            end

            S_X_W: begin
                spr_x <= x_adj;
                state <= S_FETCH;
            end

            S_FETCH: if (gfx_ack) begin
                gfx_req <= 1'b0;
                data    <= gfx_q;
                k       <= 5'd0;
                state   <= S_BLIT;
            end

            // ------------------------------------------- 16 pixels
            S_BLIT: begin
                if (pix_in && pen != 4'd0) begin
                    w_valid <= 1'b1;
                    w_x     <= pix_x[8:0];
                    w_idx   <= index;
                end
                k <= k + 5'd1;
                if (k == 5'd15) state <= S_NEXT;
            end

            // --------------------------------------------------------------
            S_NEXT: begin
                ent <= ent + 8'd1;
                if (ent == 8'd255) state <= S_IDLE;
                else               state <= S_Y;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // The table word whose answer arrives next clock.
    always_comb begin
        case (state)
        S_Y:      tab_addr = {ent, 2'd1};   // Y
        S_ATTR:   tab_addr = {ent, 2'd0};   // attribute
        S_ATTR_W: tab_addr = {ent, 2'd2};   // tile code
        S_CODE_W: tab_addr = {ent, 2'd3};   // X
        default:  tab_addr = {ent, 2'd1};
        endcase
    end

    wire _unused = &{1'b0, tab_q[15:9], spr_ctrl[15:6], spr_ctrl[1:0],
                     oj_ctrl[15:1], x_now, 1'b0};
endmodule

`default_nettype wire
