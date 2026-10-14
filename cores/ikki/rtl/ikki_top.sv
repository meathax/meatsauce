//============================================================================
// Ikki synthesis wrapper — ikki_core plus SDRAM pin handling.
//
// Keep this thin.  Everything that affects behaviour lives in ikki_core.sv so
// that the Verilator wrapper (verif/ikki_sim_top.sv) exercises the same logic.
//============================================================================
module ikki_top
(
	input         clk_sys,
	input         clk_vid,
	input         clk_mem,
	input         pll_locked,
	input         reset,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input   [7:0] ioctl_index,

	input  [15:0] joystick_0,
	input  [15:0] joystick_1,
	input   [7:0] dip_sw1,
	input   [7:0] dip_sw2,
	input         pause,

	output        ce_pix,
	output  [3:0] r,
	output  [3:0] g,
	output  [3:0] b,
	output        hs,
	output        vs,
	output        hblank,
	output        vblank,

	output [15:0] audio_l,
	output [15:0] audio_r,

	inout  [15:0] SDRAM_DQ,
	output [12:0] SDRAM_A,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output  [1:0] SDRAM_BA,
	output        SDRAM_nCS,
	output        SDRAM_nWE,
	output        SDRAM_nRAS,
	output        SDRAM_nCAS,
	output        SDRAM_CLK,
	output        SDRAM_CKE
);

ikki_core u_core
(
	.clk_sys(clk_sys),
	.clk_vid(clk_vid),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.dip_sw1(dip_sw1),
	.dip_sw2(dip_sw2),
	.pause(pause),
	.ce_pix(ce_pix),
	.r(r), .g(g), .b(b),
	.hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.spr_overflow()
);

// The SDRAM stick is not used — all ROM and RAM lives in on-chip BRAM.  Hold
// the device deselected and clocked-off rather than floating the control pins.
assign SDRAM_DQ   = 16'bZ;
assign SDRAM_A    = 13'd0;
assign SDRAM_BA   = 2'd0;
assign SDRAM_DQML = 1'b1;
assign SDRAM_DQMH = 1'b1;
assign SDRAM_nCS  = 1'b1;
assign SDRAM_nWE  = 1'b1;
assign SDRAM_nRAS = 1'b1;
assign SDRAM_nCAS = 1'b1;
assign SDRAM_CLK  = 1'b0;
assign SDRAM_CKE  = 1'b0;

wire _unused_mem = |{clk_mem, pll_locked};

endmodule
