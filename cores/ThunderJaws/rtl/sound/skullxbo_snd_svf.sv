`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: one second-order low-pass section, as a Chamberlin
//  state-variable filter.  Used by skullxbo_snd_filter for the YM2151
//  Sallen-Key (whose corner the LPF bit switches) and the OKI
//  reconstruction filter's pole pair.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Vindicators
//  core's `vind_jsa_lpf.sv` (GPL-3.0), itself the Toobin' core's
//  `toobin_jsa_lpf.sv`: the filter structure, the Q16 coefficient form and
//  the pipelined multiplies are theirs.  The coefficients are set in
//  skullxbo_snd_filter.
//
//      low  = low  + f*band
//      high = in   - low - q*band
//      band = band + f*high
//      y    = low
//  with f = 2*sin(pi*f0/fs) and q = 1/Q, both Q16 inputs (the LPF bit moves
//  f0 from 8941 Hz / Q 0.742 to 4312 Hz / Q 0.358 at run time).
//
//  A state-variable filter rather than a direct-form biquad because f0/fs is
//  0.0012-0.005 here: direct-form poles that close to z = 1 need far more
//  coefficient precision.  Stability needs f*q < 2 and f < 2; this board's
//  settings are at f*q = 0.042 (YM) and 0.010 (OKI).
//
//  State is Q16 with 18 integer bits: 2 bits of headroom, so the resonant
//  overshoot cannot wrap.  The multiplies are registered (see
//  skullxbo_snd_iir1).
//============================================================================

module skullxbo_snd_svf
(
	input  logic        clk,
	input  logic        ce,              // ce_1m79
	input  logic        reset,
	input  logic [18:0] f,               // Q16 of 2*sin(pi*f0/fs)
	input  logic [18:0] q,               // Q16 of 1/Q
	input  logic signed [17:0] x,
	output logic signed [17:0] y
);

	localparam int SW = 34;              // 18 integer + 16 fraction

	logic signed [SW-1:0] lp, bp;
	wire  signed [SW-1:0] in_q16 = {x, 16'd0};

	wire signed [19:0] f_c = $signed({1'b0, f});
	wire signed [19:0] q_c = $signed({1'b0, q});

	logic signed [SW-1:0] f_bp_r, q_bp_r, hp_r, f_hp_r;

	wire signed [SW+19:0] f_bp = f_c * bp;
	wire signed [SW+19:0] q_bp = q_c * bp;
	always_ff @(posedge clk) begin
		if (reset) begin
			f_bp_r <= '0; q_bp_r <= '0;
		end else begin
			f_bp_r <= SW'(f_bp >>> 16);
			q_bp_r <= SW'(q_bp >>> 16);
		end
	end

	wire signed [SW-1:0] lp_nxt = lp + f_bp_r;
	wire signed [SW-1:0] hp_sv  = in_q16 - lp_nxt - q_bp_r;
	always_ff @(posedge clk) begin
		if (reset) hp_r <= '0;
		else       hp_r <= hp_sv;
	end

	wire signed [SW+19:0] f_hp = f_c * hp_r;
	always_ff @(posedge clk) begin
		if (reset) f_hp_r <= '0;
		else       f_hp_r <= SW'(f_hp >>> 16);
	end

	wire signed [SW-1:0] bp_nxt = bp + f_hp_r;

	always_ff @(posedge clk) begin
		if (reset) begin
			lp <= '0; bp <= '0;
		end else if (ce) begin
			lp <= lp_nxt;
			bp <= bp_nxt;
		end
	end

	assign y = lp[SW-1:16];

endmodule
