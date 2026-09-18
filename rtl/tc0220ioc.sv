//------------------------------------------------------------------------------
// Taito TC0220IOC: the inputs, the DIP switches, the coin lockout and counter
// outputs, and the watchdog.
//
// From MAME's tc0220ioc_device (ref/mame/taitoio.cpp).  Unlike its TC0040IOC
// cousin this one is directly addressed: register n sits at offset n, and
// Cadash maps it byte-wide on the odd byte at 900000-90000F, so register n is
// at 900000 + 2n + 1.
//
//   read  0  DSWA      1  DSWB      2  player 1      3  player 2
//         4  the coin register, read back as written
//         7  system: coins, starts, service, tilt
//         anything else reads 0xFF
//   write 0  kicks the watchdog
//         4  coin lockout and counters, low nibble
//
// Every input is active low.
//------------------------------------------------------------------------------
`default_nettype none

module tc0220ioc (
    input  logic       clk,
    input  logic       rst,

    input  logic       wr,              // one clock, at the start of a write
    input  logic [2:0] addr,
    input  logic [7:0] din,
    output logic [7:0] dout,

    input  logic [7:0] dswa, dswb,
    input  logic [7:0] in0, in1, in2,

    output logic [3:0] coin_ctrl,       // lockout 1,0 then counters 2,3
    output logic       watchdog_kick
);
    logic [7:0] regs [0:7];

    always_comb begin
        case (addr)
            3'd0:    dout = dswa;
            3'd1:    dout = dswb;
            3'd2:    dout = in0;
            3'd3:    dout = in1;
            3'd4:    dout = regs[4];
            3'd7:    dout = in2;
            default: dout = 8'hff;
        endcase
    end

    always_ff @(posedge clk) begin
        watchdog_kick <= 1'b0;
        if (rst) begin
            for (int i = 0; i < 8; i++) regs[i] <= 8'd0;
        end else if (wr) begin
            regs[addr] <= din;
            if (addr == 3'd0) watchdog_kick <= 1'b1;
        end
    end

    assign coin_ctrl = regs[4][3:0];
endmodule

`default_nettype wire
