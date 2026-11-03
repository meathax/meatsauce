`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II analogue chain, modelled digitally: the
//  4066 3B volume ladder, the switched Sallen-Key filter, the TL084 6C OKI
//  reconstruction filter with its SP0 gain switch, and the 6B mixer.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The overall shape (a stage
//  chain clocked on the 6502's enable, Q16 coefficients, a saturating
//  output) follows the Bad Lands core's `badlands_snd_filter.sv` and the
//  Vindicators core's `vind_jsa_mix.sv` / `vind_jsa_lpf.sv` (GPL-3.0).  Every
//  topology, component value and coefficient below is this board's.
//
//  YM2151 -> YM3012 -> TL084 6A buffers -> the 4066 3B ladder
//  ------------------------------------------------------------
//  Each YM3012 channel drives three weighted resistors.  The matching
//  resistors of the two channels are joined and switched together by three
//  4066 sections into a virtual ground at TL084 6B (R40 20 K feedback):
//
//      3B section  control  resistors            weight
//          B        YM0     R25 / R24  30 K        1
//          A        YM1     R26 / R27  15 K        2
//          C        YM2     R21 / R28  7.5 K       4
//
//      N = 4*YM2 + 2*YM1 + YM0        relative gain = N/7   (0 = mute)
//
//  MAME's ((data >> 1) & 7) / 7.0 is exactly this law.  What MAME lacks: C24
//  (0.22 uF) sits between the ladder and the virtual ground, so the high-pass
//  corner moves with the volume.  The switched resistance is 15k/N, so
//
//      f_hp(N) = 1 / (2*pi * (15000/N) * 0.22e-6) = 48.229 * N Hz
//              (48 Hz at N = 1 ... 338 Hz at N = 7)
//
//  and the game changes N during play.
//
//  -> the switched Sallen-Key (TL084 6B, R = 12 K)
//  ------------------------------------------------------------
//      LPF   C2                 f0           Q
//       0    C39 1.0 nF         8941 Hz      0.742
//       1    C39 + C25 4.3 nF   4312 Hz      0.358
//  MAME does not implement the LPF bit; the game toggles it.
//
//  MSM6295 DA0 -> the TL084 6C chain
//  ------------------------------------------------------------
//      stage 1  unity follower
//      stage 2  low-pass, gain 3, f0 = 2164 Hz, Q = 0.751.  The stage also
//               has a transmission zero (3-15 kHz) from a feed-forward
//               branch, which is not modelled; that only affects content
//               far above the ~900 Hz pole that limits this path.
//      stage 3  first-order RC at 2340 Hz + unity follower
//      stage 4  R43 2K into node M (C27 0.1 uF), then R22 15K -- or
//               R22 || R23 = 5K when SP0 closes 4066 section D -- into the 6C
//               summing amp (R45 68K)
//
//      SP0  series  mid-band gain  node-M pole  HP corner
//       0   17 kOhm     -4.00        901 Hz      42.6 Hz
//       1    7 kOhm     -9.71       1114 Hz     103.0 Hz
//
//  So the SP0 step is x2.43 at DC rising to x3.00 above 2 kHz, not MAME's
//  flat x2.  That follows from modelling the gain and the node-M pole
//  separately.  The ~900 Hz node-M pole is what makes the board's ADPCM
//  sound so muffled.
//
//  -> the final mixer (TL084 6B, inverting, referenced to +3.5 V)
//  ------------------------------------------------------------
//      AUD - 3.5V = -( V_oki/47k + V_ym/33k ) * 10k
//  so the two paths are weighted 47 : 33:
//      w_ym = 47/80 = 0.5875      w_oki = 33/80 = 0.4125
//  The +3.5 V reference disappears in a signed digital model.  The volume
//  pot and power amp that follow are left to the MiSTer volume control.
//
//  Normalisation.  The full-scale output swings of the YM3012 and MSM6295
//  are not on the schematic, so the absolute FM : ADPCM balance cannot be
//  derived from it (MAME's 0.60 / 0.75 is a tuning choice).  So every filter
//  shape and switched step is the schematic's, each path is normalised to
//  unity at its loudest setting (YM N = 7, OKI SP0 = 1), and the two are
//  mixed in the mixer resistors' ratio, 47 : 33.  `BAL_YM` / `BAL_OKI` are
//  parameters so the balance can be changed without touching the shapes.
//
//  Rate: clocked by `ce` = ce_1m79 = 1,789,772.7 Hz.  The YM3012 (55.9 kHz)
//  and MSM6295 (7.2 kHz) outputs are sample-and-held, so filtering them at
//  this much higher rate is what the op-amp stages on the board do.
//
//  Coefficients (fs = 57,272,727 / 32):
//      1-pole  k = 1 - exp(-2*pi*fc/fs), Q20        (skullxbo_snd_iir1)
//      2-pole  f = 2*sin(pi*f0/fs), q = 1/Q, Q16    (skullxbo_snd_svf)
//  Each constant's realised corner is noted beside it; all are within 0.15 Hz
//  of the analogue value.
//============================================================================

module skullxbo_snd_filter #(
	// The mixer resistors, 47 : 33 into 10 K.  Q16, summing to
	// exactly 65536 so two simultaneously full-scale paths cannot clip.
	parameter int BAL_YM  = 38502,       // 47/80 = 0.5875
	parameter int BAL_OKI = 27034        // 33/80 = 0.4125
) (
	input  logic        clk,
	input  logic        ce,              // ce_1m79 = 1.7897727 MHz
	input  logic        reset,
	input  logic        bypass,          // 1 = the raw MAME-style sum (test only)

	// ---- LS174 3C ----
	input  logic  [2:0] ym_vol,          // N = 4*YM2 + 2*YM1 + YM0
	input  logic        lpf,             // the Sallen-Key switch
	input  logic        sp0,             // the OKI gain switch

	// ---- sources ----
	input  logic signed [15:0] ym_ch1,   // YM3012 CH1 -> TL084 6A -> the ladder
	input  logic signed [15:0] ym_ch2,   // YM3012 CH2 -> TL084 6A -> the ladder
	input  logic signed [15:0] oki_in,   // MSM6295 DA0 -> TL084 6C

	// ---- output (mono: the board has one speaker output) ----
	output logic signed [15:0] out,
	output logic        clipped,         // sticky: the saturator fired

	// ---- stage taps (debug only) ----
	output logic signed [15:0] dbg_ym_hp,   // after the ladder HP + N/7
	output logic signed [15:0] dbg_ym,      // after the Sallen-Key (path out)
	output logic signed [15:0] dbg_oki_s2,  // after the 2 164 Hz pole pair
	output logic signed [15:0] dbg_oki_s3,  // after the 2 340 Hz RC
	output logic signed [15:0] dbg_oki      // after node M + the HP (path out)
);

	// ========================================================================
	//  Coefficients.  fs = 1 789 772.73 Hz.
	// ========================================================================
	// YM ladder high-pass, f = 48.229 * N Hz.  Q20 of 1 - exp(-2*pi*f/fs).
	// N   =      0     1     2     3     4     5     6     7
	// f Hz=      -   48.2  96.5 144.7 192.9 241.1 289.4 337.6
	// got Hz=    -   48.36 96.45 144.56 192.94 241.06 289.46 337.60
	logic [19:0] k_ym_hp;
	always_comb begin
		case (ym_vol)
			3'd0:    k_ym_hp = 20'd178;    // muted anyway; keeps the state sane
			3'd1:    k_ym_hp = 20'd178;
			3'd2:    k_ym_hp = 20'd355;
			3'd3:    k_ym_hp = 20'd532;
			3'd4:    k_ym_hp = 20'd710;
			3'd5:    k_ym_hp = 20'd887;
			3'd6:    k_ym_hp = 20'd1065;
			default: k_ym_hp = 20'd1242;
		endcase
	end

	// YM volume, N/7 EXACTLY (Q16).
	logic [17:0] g_ym;
	always_comb begin
		case (ym_vol)
			3'd0:    g_ym = 18'd0;
			3'd1:    g_ym = 18'd9362;
			3'd2:    g_ym = 18'd18725;
			3'd3:    g_ym = 18'd28087;
			3'd4:    g_ym = 18'd37449;
			3'd5:    g_ym = 18'd46811;
			3'd6:    g_ym = 18'd56174;
			default: g_ym = 18'd65536;
		endcase
	end

	// The Sallen-Key, both states.  Q16 of 2*sin(pi*f0/fs) and 1/Q.
	wire [18:0] f_ym_lp = lpf ? 19'd992   : 19'd2057;    // 4 312 Hz / 8 941 Hz
	wire [18:0] q_ym_lp = lpf ? 19'd183061: 19'd88369;   // Q 0.358  / Q 0.7416

	// The OKI chain.
	localparam logic [18:0] F_OKI_S2 = 19'd498;      // 2 164 Hz
	localparam logic [18:0] Q_OKI_S2 = 19'd87265;    // Q 0.751
	localparam logic [19:0] K_OKI_S3 = 20'd8579;     // 2 340.1 Hz
	wire [19:0] k_oki_m  = sp0 ? 20'd4093 : 20'd3311; // 1 114.1 Hz / 900.9 Hz
	wire [19:0] k_oki_hp = sp0 ? 20'd379  : 20'd157;  //   103.0 Hz /  42.7 Hz
	// The SP0 gain step, normalised to the LOUD setting: 4.00/9.71 = 0.411946.
	wire [17:0] g_oki    = sp0 ? 18'd65536 : 18'd26997;

	// ========================================================================
	//  YM path
	// ========================================================================
	// The two YM3012 channels meet at identical weight in the ladder,
	// so the board sums them; the >>> 1 is part of the normalisation, not a
	// weighting (a single channel at full scale is then half scale, which is
	// what a mono FM patch on one channel produces).
	wire signed [16:0] ym_sum = {ym_ch1[15], ym_ch1} + {ym_ch2[15], ym_ch2};
	wire signed [17:0] ym_in  = {{2{ym_sum[16]}}, ym_sum[16:1]};

	wire signed [17:0] ym_hp_o;
	skullxbo_snd_iir1 #(.HIGHPASS(1'b1)) u_ym_hp (
		.clk(clk), .ce(ce), .reset(reset), .k(k_ym_hp), .x(ym_in), .y(ym_hp_o) );

	// N/7, Q16.  Registered: one multiply per ce, 32 clocks to settle.
	wire signed [35:0] ym_vol_m = ym_hp_o * $signed({1'b0, g_ym});
	logic signed [17:0] ym_vol_r;
	always_ff @(posedge clk) begin
		if (reset) ym_vol_r <= '0;
		else       ym_vol_r <= 18'(ym_vol_m >>> 16);
	end

	wire signed [17:0] ym_path;
	skullxbo_snd_svf u_ym_lp (
		.clk(clk), .ce(ce), .reset(reset), .f(f_ym_lp), .q(q_ym_lp),
		.x(ym_vol_r), .y(ym_path) );

	// ========================================================================
	//  OKI path
	// ========================================================================
	wire signed [17:0] oki_in18 = {{2{oki_in[15]}}, oki_in};

	wire signed [17:0] oki_s2;
	skullxbo_snd_svf u_oki_s2 (
		.clk(clk), .ce(ce), .reset(reset), .f(F_OKI_S2), .q(Q_OKI_S2),
		.x(oki_in18), .y(oki_s2) );

	wire signed [17:0] oki_s3;
	skullxbo_snd_iir1 #(.HIGHPASS(1'b0)) u_oki_s3 (
		.clk(clk), .ce(ce), .reset(reset), .k(K_OKI_S3), .x(oki_s2), .y(oki_s3) );

	// The SP0 gain, normalised, then the node-M pole it moves with.
	wire signed [35:0] oki_g_m = oki_s3 * $signed({1'b0, g_oki});
	logic signed [17:0] oki_g_r;
	always_ff @(posedge clk) begin
		if (reset) oki_g_r <= '0;
		else       oki_g_r <= 18'(oki_g_m >>> 16);
	end

	wire signed [17:0] oki_m;
	skullxbo_snd_iir1 #(.HIGHPASS(1'b0)) u_oki_m (
		.clk(clk), .ce(ce), .reset(reset), .k(k_oki_m), .x(oki_g_r), .y(oki_m) );

	wire signed [17:0] oki_path;
	skullxbo_snd_iir1 #(.HIGHPASS(1'b1)) u_oki_hp (
		.clk(clk), .ce(ce), .reset(reset), .k(k_oki_hp), .x(oki_m), .y(oki_path) );

	// ========================================================================
	//  The 6B summing mixer, 47 : 33
	// ========================================================================
	wire signed [35:0] mix_ym  = ym_path  * $signed({1'b0, 18'(BAL_YM)});
	wire signed [35:0] mix_oki = oki_path * $signed({1'b0, 18'(BAL_OKI)});
	logic signed [19:0] mix_r;
	always_ff @(posedge clk) begin
		if (reset) mix_r <= '0;
		else       mix_r <= 20'((mix_ym >>> 16) + (mix_oki >>> 16));
	end

	function automatic logic signed [15:0] sat16(input logic signed [19:0] v);
		if      (v >  20'sd32767) sat16 = 16'sd32767;
		else if (v < -20'sd32768) sat16 = 16'sh8000;
		else                      sat16 = v[15:0];
	endfunction

	wire sat_now = (mix_r > 20'sd32767) || (mix_r < -20'sd32768);

	logic clip_sticky;
	always_ff @(posedge clk) begin
		if (reset)                        clip_sticky <= 1'b0;
		else if (ce && sat_now && !bypass) clip_sticky <= 1'b1;
	end
	assign clipped = clip_sticky;

	// `bypass` is MAME's model: no filter, no ladder law, the raw sum.  Test
	// only; the core ties it to 0.
	wire signed [19:0] raw = {{3{ym_sum[16]}}, ym_sum} + {{4{oki_in[15]}}, oki_in};
	assign out = bypass ? sat16(raw) : sat16(mix_r);

	// ---- taps ---------------------------------------------------------------
	assign dbg_ym_hp  = sat16({{2{ym_vol_r[17]}}, ym_vol_r});
	assign dbg_ym     = sat16({{2{ym_path[17]}},  ym_path});
	assign dbg_oki_s2 = sat16({{2{oki_s2[17]}},   oki_s2});
	assign dbg_oki_s3 = sat16({{2{oki_s3[17]}},   oki_s3});
	assign dbg_oki    = sat16({{2{oki_path[17]}}, oki_path});

endmodule
