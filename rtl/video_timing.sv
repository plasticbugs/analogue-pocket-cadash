//------------------------------------------------------------------------------
// Video timing for the TC0100SCN's raster, retuned for a 96 MHz system clock.
//
// The chip's own raster is 424 x 262 at 26.686 MHz / 4 = 6.6715 MHz
// (ref/taitof2/rtl/video_timing.sv, which is where that number comes from --
// MAME does not model the dot clock at all).  96 MHz has no useful ratio with
// 26.686 MHz, so the core runs the dots 2.8% fast at 96/14 = 6.857 MHz and
// takes the horizontal total back the other way, 436 instead of 424.  The line
// and frame rates then land within 0.06% of the board's; see
// docs/core-design.md section 2.
//
// Cadash is ROT0 and its visible window is 320 x 240, the same window MAME
// declares (asuka.cpp: 40*8 x 32*8 with visarea y 2*8..32*8-1).
//------------------------------------------------------------------------------
`default_nettype none

module video_timing (
    input  logic       clk,
    input  logic       reset,

    output logic       ce_pix,      // one system clock in fourteen
    output logic [8:0] hcnt,        // 0..435
    output logic [8:0] vcnt,        // 0..261
    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       de,          // inside the 320 x 240 window

    output logic       line_start,  // ce_pix && hcnt == 0
    output logic       frame_start  // ce_pix && hcnt == 0 && vcnt == 0
);
    localparam int H_TOTAL  = 436;
    localparam int H_VIS    = 320;
    localparam int HS_START = 340;
    localparam int HS_END   = 380;

    localparam int V_TOTAL  = 262;
    localparam int V_VIS    = 240;
    localparam int VS_START = 244;
    localparam int VS_END    = 250;

    logic [3:0] div;

    always_ff @(posedge clk) begin
        if (reset) begin
            div  <= '0;
            hcnt <= '0;
            vcnt <= '0;
        end else begin
            div <= (div == 4'd13) ? 4'd0 : div + 4'd1;
            if (ce_pix) begin
                if (hcnt == 9'(H_TOTAL - 1)) begin
                    hcnt <= '0;
                    vcnt <= (vcnt == 9'(V_TOTAL - 1)) ? 9'd0 : vcnt + 9'd1;
                end else begin
                    hcnt <= hcnt + 9'd1;
                end
            end
        end
    end

    assign ce_pix      = (div == 4'd13);
    assign hblank      = hcnt >= 9'(H_VIS);
    assign vblank      = vcnt >= 9'(V_VIS);
    assign hsync       = hcnt >= 9'(HS_START) && hcnt < 9'(HS_END);
    assign vsync       = vcnt >= 9'(VS_START) && vcnt < 9'(VS_END);
    assign de          = !hblank && !vblank;
    assign line_start  = ce_pix && hcnt == 9'(H_TOTAL - 1);
    assign frame_start = line_start && vcnt == 9'(V_TOTAL - 1);
endmodule

`default_nettype wire
