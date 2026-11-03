//============================================================================
//  Xybots (Atari Games, 1987) — JSA I audio output filter (SP-313 sheet 13).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_lpf.sv
//  (GPL-3.0-or-later); see NOTICE.md.  Both games carry the same Stand-Alone
//  Audio PCB, and the reference designators and part values on SP-313 sheet 13
//  are identical to SP-320 sheet 21, so the derived coefficients transfer
//  unchanged.
//
//  Each channel leaves the /MIX summing amp through a unity-gain Sallen-Key
//  low-pass built around LM324 4A:
//
//    in --[R44 12K]--+--[R45 12K]--+-- (+) 4A >--+-- LAUD
//                    |             |             |
//                  C53 .0022 ------+             |   (feedback to the R44/R45 node)
//                                  |             |
//                           C55 .001 to AGND     +-- (-) 4A   (follower)
//                                  |
//                           C54 .0027 to AGND via Q5
//
//  Right channel is the same parts: R46/R47, C58, C57, C56, Q6, R59, R60.
//
//  Q5/Q6 (2N3904) shunt C54/C56 to AGND, adding them in parallel with C55/C57
//  and dropping the corner.  The base is driven through R58 1K from LPF *and*
//  R57 1K from YM0 — the schematic prints "OR" between them — so the filter
//  engages on (/MIX bit 0 | /MIX bit 1), not on the LPF bit alone.  With Q5
//  off, C54 sees R56 150K to AGND, high against its own reactance in band, so
//  it is effectively out of circuit.
//
//  For R1=R2=R and this topology:  w0 = 1/(R*sqrt(C1*C2)),  Q = 0.5*sqrt(C1/C2)
//
//    disengaged  C2 = C55            = 1.0 nF -> fc = 8941.9 Hz, Q = 0.7416
//    engaged     C2 = C55 + C54      = 3.7 nF -> fc = 4648.6 Hz, Q = 0.3855
//
//  Note w0/Q = 2/(R*C1) is independent of C2, so f*q is the same in both
//  states and only the frequency coefficient switches.
//
//  Realised as a Chamberlin state-variable filter clocked by `ce`, which on
//  this board is ce_6502 = 1.7897725 MHz.  An SVF is used rather than a
//  direct-form biquad because fc/fs here is 0.0026-0.0050: direct-form poles
//  that close to z=1 need far more coefficient precision to stay accurate,
//  while the SVF is parameterised directly by the (f, q) the schematic gives.
//
//    f = 2*sin(pi*fc/fs)   q = 1/Q     both Q16
//
//  Stability needs f*q < 2 and f < 2; both states sit at f*q = 0.0423.
//
//  bypass=1 passes the input through untouched.  It is a build-time facility
//  only — rtl/xybots_core.sv ties it to 0, so the sheet-13 filter is always in
//  circuit in the shipping core.
//============================================================================

module xybots_jsa_lpf
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,             // ce_6502: 1.7897725 MHz
	input  logic        engage,         // /MIX bit0 | bit1  (LPF or YM0)
	input  logic        bypass,
	input  logic signed [15:0] in,
	output logic signed [15:0] out
);

	// Q16 coefficients; see the derivation above.
	localparam signed [18:0] F_OPEN  = 19'sd2057;    // fc 8941.9 Hz
	localparam signed [18:0] Q_OPEN  = 19'sd88369;   // Q 0.7416
	localparam signed [18:0] F_SHUT  = 19'sd1070;    // fc 4648.6 Hz
	localparam signed [18:0] Q_SHUT  = 19'sd169981;  // Q 0.3855

	wire signed [18:0] f_c = engage ? F_SHUT : F_OPEN;
	wire signed [18:0] q_c = engage ? Q_SHUT : Q_OPEN;

	// State is Q16 with 18 integer bits: 2 bits of headroom over the 16-bit
	// sample so the (mild) resonant overshoot cannot wrap.
	localparam int SW = 34;
	logic signed [SW-1:0] lp, bp;

	wire signed [SW-1:0] in_q16 = {{(SW-32){in[15]}}, in, 16'sd0};

	// low  = low + f*band
	// high = in - low - q*band
	// band = band + f*high
	//
	// Evaluated across several clk_sys cycles rather than one.  ce fires once
	// per 32 clk_sys cycles here, so there is no need to chain two 34-bit
	// multiplies and three adds into a single cycle — and good reason not to:
	// written that way, this filter's own bp register missed setup by 11.7 ns
	// in Quartus.
	//
	// Pipelining rather than an SDC multicycle exception is deliberate: these
	// pipeline registers update on EVERY clock, so a blanket "this module only
	// moves on ce" exception would be false about precisely the registers it
	// would cover.  Everything settles within 3 clocks of a ce, against 32
	// available, and the values latched at ce are the same ones the
	// single-cycle form produced — so the response is unchanged.
	logic signed [SW-1:0] f_bp_r, q_bp_r, hp_r, f_hp_r;

	wire signed [SW+18:0] f_bp = f_c * bp;
	wire signed [SW+18:0] q_bp = q_c * bp;
	always_ff @(posedge clk) begin
		f_bp_r <= SW'(f_bp >>> 16);
		q_bp_r <= SW'(q_bp >>> 16);
	end

	wire signed [SW-1:0] lp_nxt = lp + f_bp_r;
	wire signed [SW-1:0] hp     = in_q16 - lp_nxt - q_bp_r;
	always_ff @(posedge clk) hp_r <= hp;

	wire signed [SW+18:0] f_hp = f_c * hp_r;
	always_ff @(posedge clk) f_hp_r <= SW'(f_hp >>> 16);

	wire signed [SW-1:0] bp_nxt = bp + f_hp_r;

	always_ff @(posedge clk) begin
		if (reset) begin
			lp <= '0;
			bp <= '0;
		end else if (ce) begin
			lp <= lp_nxt;
			bp <= bp_nxt;
		end
	end

	// Saturate back to 16-bit; the headroom bits should never be in use, but a
	// wrap here would be a loud click rather than a quiet inaccuracy.
	wire signed [17:0] lp_int = lp[SW-1:16];
	function automatic signed [15:0] sat16(input signed [17:0] v);
		if      (v >  18'sd32767) sat16 =  16'sd32767;
		else if (v < -18'sd32768) sat16 =  16'sh8000;
		else                      sat16 =  v[15:0];
	endfunction

	assign out = bypass ? in : sat16(lp_int);

endmodule
