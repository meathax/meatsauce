//============================================================================
//  Xybots (Atari Games, 1987) — YM2151 wrapper: the jt51 core plus the
//  6502 -> YM write bridge.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_ym.sv
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  SP-313 sheet 13, 2F-YAM: D7..D0 = SD7..SD0, PHI(24) = 3579K, A0(4) = SA0,
//  /IC(3) = /YAMRES (the /WRIO latch bit 0), /WR(5) = /SWR, /RD(6) = /SRD,
//  /CS(7) = /YAM.  SO/SH1/SH2 and the clock output drive the 2D YM3012 DAC,
//  whose CH1/CH2 feed the sheet-13 mixer.  CT1/CT2 gate the POKEY/speech sum
//  into the left/right analogue paths — on Xybots that sum is silent (both
//  sockets empty), so CT1/CT2 have no audible effect and are left unconnected
//  at the top level.
//
//  jt51 captures `write = !cs_n & !wr_n` on cen_p1, its register clock.  On
//  this board the 6502's own bus-cycle enable IS cen_p1, so a 6502 YM write
//  always lands on a cen_p1 pulse and is presented to jt51 in that same cycle,
//  with no added latency; the pending register below only holds a write over
//  to the next pulse if some other integration ever clocks the two apart.
//  Reads return jt51's status (dout) directly.  Audio is jt51's
//  full-resolution (xleft/xright) output.
//
//  ---- clock enables -------------------------------------------------------
//  clk_sys is 57.272727 MHz = 4 x the SP-313 sheet-4 crystal, and the JSA
//  crystal is exactly that crystal / 4, so `xybots_core` derives
//      ce_ym    = clk_sys/16 = 3.579545 MHz   -> cen
//      ce_6502  = clk_sys/32 = 1.7897725 MHz  -> cen_p1
//  from one free-running counter.  ce_6502 is a strict subset of ce_ym (both
//  are decodes of the same counter, ce_6502 = the even ce_ym pulses), which is
//  precisely the "cen_p1 is every other cen, aligned with it" relationship
//  jt51 expects.
//============================================================================

module xybots_ym
(
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,        // YM2151 clock enable (3.579545 MHz)
	input  logic        cen_p1,     // half-rate enable, phase-aligned with cen
	input  logic        ym_reset_n, // /YAMRES from the /WRIO latch (active low)

	// bus side (from xybots_jsa_bus)
	input  logic        ym_cs,      // access this cycle
	input  logic        ym_a0,      // register select
	input  logic        ym_we,      // write strobe (one bus cycle)
	input  logic  [7:0] ym_dout,    // 6502 -> YM data
	output logic  [7:0] ym_din,     // YM status -> 6502

	// audio + peripheral
	output logic        sample,
	output logic signed [15:0] aud_left,
	output logic signed [15:0] aud_right,
	output logic signed [15:0] aud_left_lo,
	output logic signed [15:0] aud_right_lo,
	output logic        ct1,
	output logic        ct2,
	output logic        ym_irq      // active high; the JSA wires /IRQ into the
	                                // shared 6502 IRQ net (SP-313 sheet 13/14)
);

	// ---- write bridge ----
	// jt51 samples `write = !cs_n & !wr_n` on cen_p1 (rtl/lib/jt51/hdl/jt51.v
	// line 271, jt51_mmr's `cen`), so a 6502 write has to be presented across
	// a cen_p1 pulse.  On
	// this board the 6502's own bus clock enable IS cen_p1 (xybots_jsa passes
	// ce_6502 to both), so the write strobe already lands on one — present it
	// to jt51 in that same cycle and only latch it when, on some other
	// integration, the strobe misses cen_p1.
	//
	// Why zero latency matters.  The YM2151 sets
	// BUSY when it accepts the write; the sound ROM spins on it at
	// `4F06: BIT $2001 / BPL`.  A one-cen_p1 (559 ns) delay shifts that window
	// by one 6502 cycle and occasionally costs the poll loop one extra 13-cycle
	// pass.  Normally invisible -- but this driver seeds its random effect pitch
	// from an LFSR at zero page $41 that its **idle loop** steps once per pass
	// (~27.9 kHz), so accumulated microseconds turn into semitones there.  The
	// real 2F-YAM latches on /WR + /CS during the bus cycle (SP-313 sheet 13)
	// and MAME's ymfm stamps m_busy_end at the write instant, so both the part
	// and the oracle are zero-latency; this is a one-cycle error against both.
	logic       wr_pend, wr_a0;
	logic [7:0] wr_d;
	wire        wr_cap = ym_cs & ym_we;         // one bus-cycle write strobe
	always_ff @(posedge clk) begin
		if (reset) wr_pend <= 1'b0;
		else if (wr_cap & ~cen_p1) begin        // strobe missed cen_p1: hold it
			wr_pend <= 1'b1; wr_a0 <= ym_a0; wr_d <= ym_dout;
		end else if (cen_p1) begin
			wr_pend <= 1'b0;                    // jt51 consumed it on cen_p1
		end
	end

	wire        wr_go   = wr_cap | wr_pend;
	wire        jt51_a0 = wr_cap ? ym_a0   : wr_a0;
	wire  [7:0] jt51_d  = wr_cap ? ym_dout : wr_d;

	wire irq_n;
	assign ym_irq = ~irq_n;

	jt51 u_jt51 (
		.rst    (reset | ~ym_reset_n),
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
		.left   (aud_left_lo),
		.right  (aud_right_lo),
		.xleft  (aud_left),
		.xright (aud_right)
	);

endmodule
