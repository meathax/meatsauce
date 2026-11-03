`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II: YM2151 3A + YM3012 5A, through jt51.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Bad Lands
//  core's `badlands_ym.sv` (GPL-3.0), itself the Blasteroids core's
//  `blstroid_ym.sv`: the jt51 instantiation and the write bridge are
//  unchanged.  Unlike Bad Lands, the YM2151's IRQ pin is connected here, to
//  the 6502's /IRQ.
//
//  YM2151 3A:
//     OM   = 3579K = 3.579545 MHz              -> `cen` (ce_3m58)
//     A0   = SA0      /IC = /YAMRES (LS273 4D bit 0; 0 = reset)
//     /WR  = /SWR     /RD = /SRD     /CS = /YAM     D7..D0 = SD7..SD0
//     IRQ  = /IRQ, wire-ORed with the periodic timer
//     CT1, CT2 unused on this board
//     O1, SO, SH1, SH2 -> YM3012 5A
//
//  The 6502's IRQ handler reads the YM2151 status first to tell the two IRQ
//  sources apart.  jt51's `dout` is that status (bit 7 BUSY, bits 1:0 the
//  timer flags); a read anywhere in $2000-$27FF returns it.
//
//  YM3012 5A: ICL = /YAMRES.  Its two channels go through unity followers to
//  the 4066 volume ladder, where they are summed with equal weight into one
//  mono node.  So which of jt51's `xleft` / `xright` is which channel makes
//  no difference; `xleft` -> ch1, `xright` -> ch2.
//
//  Write bridge: jt51 captures `write = !cs_n & !wr_n` on `cen_p1`.  Here
//  `cen_p1` is `ce_1m79` and the write strobe is already ce_1m79-qualified,
//  so the bridge never has to hold anything; it is kept as the proven
//  structure.  Writes must take effect at once: the YM2151 sets BUSY when it
//  accepts a write and the firmware polls that flag.
//
//  Clock enables: ce_3m58 = clk_sys/16 -> `cen`, ce_1m79 = clk_sys/32 ->
//  `cen_p1`, from one counter, so `cen_p1` is every other `cen` as jt51
//  requires.
//============================================================================

module skullxbo_ym
(
	input  logic        clk,
	input  logic        cen,        // ce_3m58 = 3.579545 MHz  (YM2151 pin 24)
	input  logic        cen_p1,     // ce_1m79 = 1.7897727 MHz, aligned with cen
	input  logic        yamres_n,   // /YAMRES (LS273 4D bit 0) -> /IC, ICL

	// bus side (from skullxbo_snd_bus)
	input  logic        ym_cs,      // /YAM asserted
	input  logic        ym_a0,      // SA0
	input  logic        ym_we,      // /SWR & /YAM
	input  logic  [7:0] ym_dout,    // 6502 -> YM
	output logic  [7:0] ym_din,     // YM status -> 6502 (bit 7 = BUSY)

	// pin 2 -- the 6502 /IRQ wire-OR
	output logic        ym_irq,     // 1 = asserted (the pin is active low)
	output logic        ct1,
	output logic        ct2,

	// audio: CH1 / CH2 into the volume ladder, equal weight
	output logic        sample,
	output logic signed [15:0] aud_ch1,
	output logic signed [15:0] aud_ch2
);

	// ---- write bridge -------------------------------------------------------
	logic       wr_pend, wr_a0;
	logic [7:0] wr_d;
	initial begin wr_pend = 1'b0; wr_a0 = 1'b0; wr_d = 8'h00; end
	wire        wr_cap = ym_cs & ym_we;
	// NOTE: `always @(posedge clk)`, not `always_ff`: these registers take
	// their power-up value from the `initial` above, and IEEE 1800 9.2.2.4
	// forbids an always_ff variable being written by another process.
	always @(posedge clk) begin
		if (~yamres_n) begin
			wr_pend <= 1'b0;
		end else if (wr_cap & ~cen_p1) begin   // strobe missed cen_p1: hold it
			wr_pend <= 1'b1; wr_a0 <= ym_a0; wr_d <= ym_dout;
		end else if (cen_p1) begin
			wr_pend <= 1'b0;                   // jt51 consumed it on cen_p1
		end
	end

	wire       wr_go   = wr_cap | wr_pend;
	wire       jt51_a0 = wr_cap ? ym_a0   : wr_a0;
	wire [7:0] jt51_d  = wr_cap ? ym_dout : wr_d;

	wire irq_n;
	wire signed [15:0] lo_l_nc, lo_r_nc;

	// The instance MUST be named `u_jt51` -- SkullXBones.sdc addresses the
	// core as *u_sound|u_ym|u_jt51|...
	jt51 u_jt51 (
		.rst    (~yamres_n),      // /IC (pin 3) -- the ONLY reset the chip has
		.clk    (clk),
		.cen    (cen),
		.cen_p1 (cen_p1),
		.cs_n   (~wr_go),
		.wr_n   (~wr_go),
		.a0     (jt51_a0),
		.din    (jt51_d),
		.dout   (ym_din),
		.ct1    (ct1),
		.ct2    (ct2),
		.irq_n  (irq_n),
		.sample (sample),
		.left   (lo_l_nc),
		.right  (lo_r_nc),
		.xleft  (aud_ch1),
		.xright (aud_ch2)
	);

	// pin 2 is an open-collector pull-down on /IRQ; export it asserted-high.
	assign ym_irq = ~irq_n;

	// MAME JSA-II gates the OKI route with YM2151 CT1. CT2 is unused here.
	// The board's YM3012 gets the full-resolution serial stream xleft/xright.
	wire _unused_ym = &{ 1'b0, ct2, lo_l_nc, lo_r_nc };

endmodule
