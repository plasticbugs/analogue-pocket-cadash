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
// Finding the next sprite and writing the current one run side by side, with a
// one-entry slot between them, so a sprite costs the larger of its 16 pixels
// and its fetch rather than the sum.  Entries that miss the line cost two
// clocks, because only their Y word is read.
//------------------------------------------------------------------------------
`default_nettype none

module sprite_line (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,
    input  logic        drop,          // give up: the line ran out of time
    input  logic  [8:0] row,            // MAME bitmap row, 16..255
    output logic        busy,

    input  logic [15:0] spr_ctrl,       // the write-only register at 080000
    input  logic [15:0] oj_ctrl,        // sprite RAM word 0xDFF

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
    // ---------------------------------------------------------- the scanner
    typedef enum logic [2:0] {
        F_IDLE, F_Y, F_Y_W, F_ATTR, F_ATTR_W, F_CODE_W, F_X_W, F_FETCH
    } fstate_t;

    fstate_t     fs;
    logic  [7:0] ent;                   // which of the 256 entries
    logic        flip_all;
    logic        last_ent;              // the scan has reached the end
    logic  [3:0] sub_y;                 // row within the sprite

    // the one-entry slot between scanner and blitter
    logic        slot_full;
    logic [15:0] p_attr;
    logic signed [10:0] p_x;
    logic [63:0] p_data;

    // A word of Y or X, sign-extended the way the chip treats it.
    function automatic logic signed [10:0] coord(input logic [8:0] v);
        coord = (v > 9'd320) ? (11'(v) - 11'sd512) : 11'(v);
    endfunction

    wire signed [10:0] c_now = coord(tab_q[8:0]);
    // The flip adjustment is 320-x-16 and 256-y-16; the (0, 8) offsets go on
    // after it.
    wire signed [10:0] y_adj = (flip_all ? (11'sd240 - c_now) : c_now) + 11'sd8;
    wire signed [10:0] x_adj = (flip_all ? (11'sd304 - c_now) : c_now);

    wire signed [10:0] rel     = 11'(row) - y_adj;
    wire               on_line = (rel >= 11'sd0) && (rel <= 11'sd15);
    wire               flipy   = flip_all ^ p_attr[15];

    always_ff @(posedge clk) begin
        if (reset || drop) begin
            fs       <= F_IDLE;
            gfx_req  <= 1'b0;
            last_ent <= 1'b1;
        end else begin
            case (fs)
            F_IDLE: if (start) begin
                ent      <= 8'd0;
                flip_all <= ~oj_ctrl[0];
                last_ent <= 1'b0;
                fs       <= F_Y;
            end

            F_Y: fs <= F_Y_W;

            F_Y_W: begin
                sub_y <= 4'(rel);
                if (on_line) begin
                    fs <= F_ATTR;
                end else if (ent == 8'd255) begin
                    last_ent <= 1'b1;
                    fs       <= F_IDLE;
                end else begin
                    ent <= ent + 8'd1;
                    fs  <= F_Y;
                end
            end

            F_ATTR: fs <= F_ATTR_W;

            F_ATTR_W: begin
                p_attr <= tab_q;
                fs     <= F_CODE_W;
            end

            F_CODE_W: begin
                gfx_req  <= 1'b1;
                gfx_addr <= {tab_q[11:0], flipy ? (4'd15 - sub_y) : sub_y};
                fs       <= F_X_W;
            end

            F_X_W: begin
                p_x <= x_adj;
                fs  <= F_FETCH;
            end

            // Hold the finished entry until the blitter has taken the previous
            // one, then hand it over and carry on scanning.
            F_FETCH: begin
                if (gfx_ack) begin
                    gfx_req <= 1'b0;
                    p_data  <= gfx_q;
                end
                if ((gfx_ack || !gfx_req) && !slot_full) begin
                    if (ent == 8'd255) begin
                        last_ent <= 1'b1;
                        fs       <= F_IDLE;
                    end else begin
                        ent <= ent + 8'd1;
                        fs  <= F_Y;
                    end
                end
            end

            default: fs <= F_IDLE;
            endcase
        end
    end

    wire slot_fill = (fs == F_FETCH) && (gfx_ack || !gfx_req) && !slot_full;

    // ---------------------------------------------------------- the blitter
    logic        running;
    logic [15:0] b_attr;
    logic signed [10:0] b_x;
    logic [63:0] b_data;
    logic  [4:0] k;                     // pixel within the sprite, 0..15

    wire  [7:0] colbank = {spr_ctrl[5:2], 4'd0};
    wire        b_flipx = flip_all ^ b_attr[14];
    wire  [3:0] kk      = b_flipx ? (4'd15 - k[3:0]) : k[3:0];
    wire  [5:0] nib     = 6'd63 - {kk, 2'b00};
    wire  [3:0] pen     = b_data[nib -: 4];
    wire [11:0] index   = {colbank[7:4], b_attr[3:0], pen};

    wire signed [10:0] pix_x  = b_x + 11'(k);
    wire               pix_in = (pix_x >= 11'sd0) && (pix_x <= 11'sd319);

    // The read issued for pixel k is answered as k+1 is issued, so the write
    // for pixel k lands one clock after that.
    logic        w_valid;
    logic  [8:0] w_x;
    logic [11:0] w_idx;

    assign lb_rd_x = pix_x[8:0];

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;
        w_valid <= 1'b0;

        if (reset || drop) begin
            running   <= 1'b0;
            slot_full <= 1'b0;
        end else begin
            if (slot_fill) slot_full <= 1'b1;

            if (w_valid && !lb_rd_q[13]) begin
                lb_we <= 1'b1;
                lb_x  <= w_x;
                // claim the pixel either way; draw only where the text layer
                // did not
                lb_d  <= {1'b1, lb_rd_q[12], lb_rd_q[12] ? lb_rd_q[11:0] : w_idx};
            end

            // Taking the next sprite has to wait for the previous one's last
            // write to reach the line buffer, or a sprite whose left edge
            // lands on the previous sprite's right edge reads a stale entry
            // and draws over it.
            if (!running) begin
                if (slot_full && !slot_fill && !w_valid && !lb_we) begin
                    b_attr    <= p_attr;
                    b_x       <= p_x;
                    b_data    <= p_data;
                    slot_full <= 1'b0;
                    k         <= 5'd0;
                    running   <= 1'b1;
                end
            end else begin
                if (pix_in && pen != 4'd0) begin
                    w_valid <= 1'b1;
                    w_x     <= pix_x[8:0];
                    w_idx   <= index;
                end
                k <= k + 5'd1;
                if (k == 5'd15) running <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------- bookkeeping
    assign busy = (fs != F_IDLE) || !last_ent || slot_full || running
                  || w_valid || lb_we;

    always_ff @(posedge clk) begin
        if (reset)        cycles <= '0;
        else if (start)   cycles <= '0;
        else if (busy)    cycles <= cycles + 16'd1;
    end

    // The table word whose answer arrives next clock.
    always_comb begin
        case (fs)
        F_Y:      tab_addr = {ent, 2'd1};   // Y
        F_ATTR:   tab_addr = {ent, 2'd0};   // attribute
        F_ATTR_W: tab_addr = {ent, 2'd2};   // tile code
        F_CODE_W: tab_addr = {ent, 2'd3};   // X
        default:  tab_addr = {ent, 2'd1};
        endcase
    end

    wire _unused = &{1'b0, tab_q[15:9], spr_ctrl[15:6], spr_ctrl[1:0],
                     oj_ctrl[15:1], 1'b0};
endmodule

`default_nettype wire
