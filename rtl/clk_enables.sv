//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 2).
//
// Every clock on the board is an exact divider of 96 MHz, so these are plain
// counters with no fractional accumulator anywhere:
//
//   cen_phi1 / cen_phi2   fx68k's two phases, a 16 MHz 68000 between them
//   cen_z80               4 MHz
//   cen_ym / cen_ym_p1    4 MHz and 2 MHz, which is what jt51 wants
//
// The dot clock is the one rate that is not the board's; it is divided by
// rtl/video_timing.sv, which also says why.
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    input  logic pause,     // hold both CPUs and the sound chip; see below
    output logic cen_phi1,
    output logic cen_phi2,
    output logic cen_z80,
    output logic cen_ym,
    output logic cen_ym_p1
);
    logic [2:0] d6;         // 0..5,  the 68000
    logic [4:0] d24;        // 0..23, the Z80 and the YM2151
    logic       ym_half;

    always_ff @(posedge clk) begin
        if (rst) begin
            d6      <= 3'd0;
            d24     <= 5'd0;
            ym_half <= 1'b0;
        end else if (!pause) begin
            d6  <= (d6  == 3'd5)  ? 3'd0 : d6  + 3'd1;
            d24 <= (d24 == 5'd23) ? 5'd0 : d24 + 5'd1;
            if (cen_ym) ym_half <= ~ym_half;
        end
    end

    // Pausing freezes the dividers and masks the enables with the same signal,
    // so every count still produces exactly one pulse: nothing is skipped and
    // nothing fires twice, and fx68k's two phases come back in the order they
    // stopped.  The dot clock is not divided here and keeps running, which is
    // what leaves the picture on the screen behind the Pocket's menu.
    wire run = !pause;
    assign cen_phi1  = run && (d6  == 3'd0);    // 96 / 6 = 16 MHz
    assign cen_phi2  = run && (d6  == 3'd3);
    assign cen_z80   = run && (d24 == 5'd1);    // 96 / 24 = 4 MHz
    assign cen_ym    = run && (d24 == 5'd2);    // 96 / 24 = 4 MHz
    assign cen_ym_p1 = cen_ym && ym_half;   // half of it, as jt51 expects
endmodule

`default_nettype wire
