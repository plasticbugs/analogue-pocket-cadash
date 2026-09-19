//------------------------------------------------------------------------------
// The whole board: both CPUs, the four Taito customs and the sound chip.
//
// Everything above this level is platform: the ROM ports go to whatever the
// host puts the 1.6 MB image in, and the video and audio come out in the
// arcade's own terms -- 320x240 at the chip's raster, and one signed 16-bit
// stream at the YM2151's rate.
//------------------------------------------------------------------------------
`default_nettype none

module cadash_core (
    input  logic        clk,            // 96 MHz
    input  logic        reset,
    input  logic        pause,          // freeze the machine, keep the picture
    input  logic        pix_sync,       // pins the dot divider to the video clock

    // ---------------- the ROM image ----------------
    output logic        mrom_req,  output logic [18:1] mrom_addr,
    input  logic        mrom_ack,  input  logic [15:0] mrom_q,

    output logic        srom_req,  output logic [15:0] srom_addr,
    input  logic        srom_ack,  input  logic  [7:0] srom_q,

    output logic        tile_req,  output logic [16:0] tile_addr,
    input  logic        tile_ack,  input  logic [31:0] tile_q,

    output logic        obj_req,   output logic [15:0] obj_addr,
    input  logic        obj_ack,   input  logic [63:0] obj_q,

    // ---------------- controls ----------------
    input  logic  [7:0] dswa, dswb,
    input  logic  [7:0] in0, in1, in2,
    output logic  [3:0] coin_ctrl,

    // ---------------- outputs ----------------
    output logic        ce_pix,
    output logic  [7:0] red, green, blue,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic [11:0] pix_index,  // the palette index behind the colour
    output logic signed [15:0] sound,

    // ---------------- diagnostics ----------------
    output logic [15:0] dbg_tile_cycles,
    output logic [15:0] dbg_obj_cycles,
    output logic  [7:0] dbg_line_overrun,
    output logic        dbg_halted
);
    logic cen_phi1, cen_phi2, cen_z80, cen_ym, cen_ym_p1;

    clk_enables u_cen (
        .clk, .rst(reset), .pause,
        .cen_phi1, .cen_phi2, .cen_z80, .cen_ym, .cen_ym_p1
    );

    // ---------------------------------------------------------------- video
    logic        vram_cs, ctrl_cs, spr_cs, pal_cs, sprctl_cs;
    logic [14:0] vid_addr;
    logic [15:0] vid_din, vid_dout;
    logic  [1:0] vid_ds;
    logic        vid_we;
    logic  [8:0] vcnt;

    cadash_video u_video (
        .clk, .reset, .pix_sync,
        .vram_cs, .ctrl_cs, .spr_cs, .pal_cs, .sprctl_cs,
        .cpu_addr(vid_addr), .cpu_din(vid_din), .cpu_ds(vid_ds),
        .cpu_we(vid_we), .cpu_dout(vid_dout),
        .tile_req, .tile_addr, .tile_ack, .tile_q,
        .obj_req,  .obj_addr,  .obj_ack,  .obj_q,
        .ce_pix, .red, .green, .blue,
        .hsync, .vsync, .hblank, .vblank, .de, .vcnt,
        .pix_index,
        .tile_cycles(dbg_tile_cycles), .obj_cycles(dbg_obj_cycles),
        .line_overrun(dbg_line_overrun)
    );

    // The 68000's vblank interrupt is edge-triggered off the chip's own
    // vertical blanking, which starts at line 240.
    logic vb_d, vblank_rise;
    always_ff @(posedge clk) begin
        vb_d        <= vblank;
        vblank_rise <= vblank & ~vb_d;
    end

    // ------------------------------------------------------------ 68000 side
    logic       ioc_wr;
    logic [2:0] ioc_addr;
    logic [7:0] ioc_din, ioc_dout;
    logic       m_port_wr, m_comm_wr, m_comm_rd;
    logic [7:0] m_din, m_dout;

    cadash_main u_main (
        .clk, .rst(reset), .cen_phi1, .cen_phi2,
        .rom_req(mrom_req), .rom_addr(mrom_addr),
        .rom_ack(mrom_ack), .rom_q(mrom_q),
        .vram_cs, .ctrl_cs, .spr_cs, .pal_cs, .sprctl_cs,
        .vid_addr, .vid_din, .vid_ds, .vid_we, .vid_dout,
        .vblank_rise,
        .ioc_wr, .ioc_addr, .ioc_din, .ioc_dout,
        .ciu_port_wr(m_port_wr), .ciu_comm_wr(m_comm_wr),
        .ciu_comm_rd(m_comm_rd), .ciu_din(m_din), .ciu_dout(m_dout),
        .dbg_halted, .dbg_addr()
    );

    tc0220ioc u_ioc (
        .clk, .rst(reset),
        .wr(ioc_wr), .addr(ioc_addr), .din(ioc_din), .dout(ioc_dout),
        .dswa, .dswb, .in0, .in1, .in2,
        .coin_ctrl, .watchdog_kick()
    );

    // ------------------------------------------------------------ sound side
    logic       s_port_wr, s_comm_wr, s_comm_rd;
    logic [7:0] s_din, s_dout;
    logic       ciu_nmi, ciu_reset;

    pc060ha u_ciu (
        .clk, .rst(reset),
        .master_port_wr(m_port_wr), .master_comm_wr(m_comm_wr),
        .master_comm_rd(m_comm_rd), .master_din(m_din), .master_dout(m_dout),
        .slave_port_wr(s_port_wr), .slave_comm_wr(s_comm_wr),
        .slave_comm_rd(s_comm_rd), .slave_din(s_din), .slave_dout(s_dout),
        .nmi(ciu_nmi), .snd_reset(ciu_reset)
    );

    cadash_sound u_sound (
        .clk, .rst(reset),
        .cen_cpu(cen_z80), .cen_ym, .cen_ym_p1,
        .rom_req(srom_req), .rom_addr(srom_addr),
        .rom_ack(srom_ack), .rom_q(srom_q),
        .ciu_port_wr(s_port_wr), .ciu_comm_wr(s_comm_wr),
        .ciu_comm_rd(s_comm_rd), .ciu_din(s_din), .ciu_dout(s_dout),
        .ciu_nmi, .ciu_reset,
        .sound
    );

    wire _unused = &{1'b0, vcnt, 1'b0};
endmodule

`default_nettype wire
