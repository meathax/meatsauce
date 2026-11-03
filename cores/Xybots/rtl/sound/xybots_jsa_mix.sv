//============================================================================
//  Xybots (Atari Games, 1987) — JSA I audio mixer (/MIX, 0x2A06).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_mix.sv
//  (GPL-3.0-or-later), with the POKEY and speech paths removed; see NOTICE.md.
//
//  ---- the register (SP-313 sheet 12/13) -----------------------------------
//  /MIX clocks the 5F 74LS273B, cleared by /POR, so every bit powers up at 0
//  (all sources muted, filter disengaged) until the 6502 writes it:
//
//    D7 -> SM2   speech volume bit 1   \  TMS5220 socket EMPTY on Xybots:
//    D6 -> SM1   speech volume bit 0   /  these two switch nothing.
//    D5 -> PM2   POKEY  volume bit 1   \  POKEY socket EMPTY on Xybots:
//    D4 -> PM1   POKEY  volume bit 0   /  these two switch nothing.
//    D3 -> YM2   YM2151 volume bit 2
//    D2 -> YM1   YM2151 volume bit 1
//    D1 -> YM0   YM2151 volume bit 0
//    D0 -> LPF   output low-pass enable
//
//  ---- the analogue mixer (SP-313 sheet 13) --------------------------------
//  4066B analogue switches at 5C (left) and 5D (right) shunt binary-weighted
//  resistors into a virtual-earth summing amp (4B LM324, referenced to 2.5 V):
//      YM2 -> 7.5K  (R62 left / R69 right)
//      YM1 -> 15K   (R64 / R67)
//      YM0 -> 30K   (R63 / R68)
//  Conductances 4 : 2 : 1, so the YM2151 volume really is a linear (D3:D1)/7
//  attenuator — which is exactly MAME's
//  `m_ym2151_volume = ((data >> 1) & 7) / 7.0`.
//  The remaining switched input is `PS` through 12K, R65 gated by the YM2151's
//  CT1 into the left channel and R66 gated by CT2 into the right.  `PS` is the
//  POKEY + speech sum (PM2 75K, PM1 150K, SM2 75K, SM1 150K into R38 47K).
//  **On Xybots both of those sockets are empty, so PS is silent** and the
//  entire CT1/CT2 stereo-gating path, plus /MIX bits 7:4, are no-ops.  They
//  are decoded, latched and then ignored, which is what the real board does.
//
//  Division by 7 uses a reciprocal multiply (x*9363>>16 ~= /7).  The combined
//  volume x reciprocal coefficient is selected BEFORE the sample multiply:
//  algebraically identical to (sample * volume) * reciprocal, but it avoids a
//  two-DSP combinational chain.
//
//  With POKEY and speech gone the YM2151 is the only source, so nothing is
//  added and the saturation below can only trigger at the signed rails; it is
//  kept anyway because it costs nothing and a wrap would be an audible click.
//============================================================================

module xybots_jsa_mix
(
	input  logic        clk,
	input  logic        reset,
	input  logic        mix_wr,
	input  logic  [7:0] mix_data,
	input  logic signed [15:0] ym_left,
	input  logic signed [15:0] ym_right,
	output logic signed [15:0] out_left,
	output logic signed [15:0] out_right,
	output logic               lpf_engage    // -> xybots_jsa_lpf
);

	logic [2:0] ym_vol; logic lpf;
	always_ff @(posedge clk) begin
		if (reset) begin ym_vol <= 3'd0; lpf <= 1'b0; end
		else if (mix_wr) begin ym_vol <= mix_data[3:1]; lpf <= mix_data[0]; end
	end
	// D7:D6 speech volume, D5:D4 POKEY volume — both sockets empty on Xybots.
	wire unused = &{1'b0, mix_data[7:4]};

	// Sheet 13 drives the Q5/Q6 filter switch from R58 (LPF) *and* R57 (YM0)
	// into the same base, drawn with "OR" between them, so the output low-pass
	// engages on either bit rather than on the LPF bit alone.  That same "OR"
	// can also be read as an alternative-*population* marking (stuff R57 or
	// R58, not both), which would make the filter follow one bit only; the two
	// readings cannot be told apart from the drawing.  On Xybots they cannot be
	// told apart from behaviour either: the sound ROM writes exactly two /MIX
	// values, 0x3C (LPF=0, YM0=0) and 0x3F (LPF=1, YM0=1), so D0 and D1 are
	// always equal and `lpf | ym_vol[0]` == `lpf` == `ym_vol[0]` for every value
	// the hardware ever sees.  The OR is kept because it gives the right answer
	// under either reading, including either single-resistor build.
	assign lpf_engage = lpf | ym_vol[0];

	// Precomputed volume*reciprocal coefficients.  Max = 7*9363 = 65541.
	logic signed [17:0] ym_gain;
	always_comb begin
		case (ym_vol)
			3'd0: ym_gain = 18'sd0;
			3'd1: ym_gain = 18'sd9363;
			3'd2: ym_gain = 18'sd18726;
			3'd3: ym_gain = 18'sd28089;
			3'd4: ym_gain = 18'sd37452;
			3'd5: ym_gain = 18'sd46815;
			3'd6: ym_gain = 18'sd56178;
			default: ym_gain = 18'sd65541;
		endcase
	end

	wire signed [33:0] ym_l_m = $signed(ym_left)  * $signed(ym_gain);
	wire signed [33:0] ym_r_m = $signed(ym_right) * $signed(ym_gain);
	wire signed [18:0] sum_l  = 19'(ym_l_m >>> 16);
	wire signed [18:0] sum_r  = 19'(ym_r_m >>> 16);

	function automatic signed [15:0] sat16(input signed [18:0] v);
		if      (v >  19'sd32767)  sat16 =  16'sd32767;
		else if (v < -19'sd32768)  sat16 =  16'sh8000;   // -32768
		else                       sat16 = v[15:0];
	endfunction

	always_ff @(posedge clk) begin
		out_left  <= sat16(sum_l);
		out_right <= sat16(sum_r);
	end

endmodule
