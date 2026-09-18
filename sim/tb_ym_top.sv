//------------------------------------------------------------------------------
// A YM2151 on its own, driven exactly the way rtl/cadash_sound.sv drives it.
//
// The whole-machine bench can say the Z80 writes the chip thousands of times
// and hears nothing, but it cannot say whether the fault is the sound driver
// or the way the core presents a write.  This asks the second question on its
// own: it plays one note with a known patch and reports whether anything came
// out, in seconds rather than minutes.
//------------------------------------------------------------------------------
`default_nettype none

module tb_ym_top (
    input  logic       clk,
    input  logic       reset,

    // one register write, held the way the core holds it
    input  logic       wr,              // pulse for one clock
    input  logic       a0,
    input  logic [7:0] din,

    output logic       busy,
    output logic       pend,
    output logic       ct1, ct2,
    output logic signed [15:0] left, right
);
    // the core's clock enables: 96 / 24 = 4 MHz, and half of it
    logic [4:0] d24;
    logic       ym_half;
    wire        cen_ym    = (d24 == 5'd2);
    wire        cen_ym_p1 = cen_ym && ym_half;

    always_ff @(posedge clk) begin
        if (reset) begin
            d24 <= '0; ym_half <= 1'b0;
        end else begin
            d24 <= (d24 == 5'd23) ? 5'd0 : d24 + 5'd1;
            if (cen_ym) ym_half <= ~ym_half;
        end
    end

    // the core's write latch
    logic       ym_pend;
    logic       ym_a0_l;
    logic [7:0] ym_din_l;

    always_ff @(posedge clk) begin
        if (reset) begin
            ym_pend <= 1'b0;
        end else if (wr) begin
            ym_pend  <= 1'b1;
            ym_a0_l  <= a0;
            ym_din_l <= din;
        end else if (ym_pend && cen_ym_p1) begin
            ym_pend <= 1'b0;
        end
    end
    assign pend = ym_pend;

    logic [7:0] dout;

    jt51 ym (
        .rst(reset), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym_p1),
        .cs_n(~ym_pend), .wr_n(~ym_pend), .a0(ym_pend ? ym_a0_l : a0),
        .din(ym_din_l), .dout(dout),
        .ct1(ct1), .ct2(ct2), .irq_n(), .sample(),
        .left(left), .right(right), .xleft(), .xright()
    );

    assign busy = dout[7];
endmodule

`default_nettype wire
