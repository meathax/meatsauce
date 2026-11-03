`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones: one first-order RC section, as a leaky integrator.
//  Used by skullxbo_snd_filter for every single-pole stage of the JSA Audio
//  II analogue chain.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The leaky-integrator form and
//  the pipelined multiply come from the Bad Lands core's
//  `badlands_snd_filter.sv` (GPL-3.0), factored out here into one module
//  per stage.
//
//      st += k * (x - st)          k = 1 - exp(-2*pi*fc/fs)   (Q20, `k`)
//      y   = st                    low-pass   (HIGHPASS = 0)
//      y   = x - st                high-pass  (HIGHPASS = 1, a DC blocker)
//
//  `k` is an input, not a parameter, because three poles on this board move
//  at run time: the OKI node-M pole and its high-pass corner follow SP0, and
//  the YM ladder's high-pass corner follows the volume N.  Changing `k`
//  between samples is what the 4066 switches do to the real network.
//
//  fs = ce_1m79 = 1,789,772.7 Hz, so every corner is at fc/fs <= 0.005 and
//  the leaky integrator is within 0.02 % of the analogue pole.  `st` is Q20
//  with 18 integer bits (2 bits of headroom over the 16-bit sample).
//
//  The multiply is registered rather than chained into the `ce` cycle (there
//  are 32 clocks between enables); chained, it misses setup at 57.27 MHz.  A
//  multicycle SDC exception would be wrong here, since these registers
//  update every clock.
//============================================================================

module skullxbo_snd_iir1 #(
	parameter bit HIGHPASS = 1'b0        // 0 = low-pass, 1 = DC-blocking high-pass
) (
	input  logic        clk,
	input  logic        ce,              // ce_1m79
	input  logic        reset,
	input  logic [19:0] k,               // Q20 of 1 - exp(-2*pi*fc/fs)
	input  logic signed [17:0] x,
	output logic signed [17:0] y
);

	localparam int HW = 38;              // 18 integer + 20 fraction

	logic signed [HW-1:0] st;
	wire  signed [HW-1:0] x_q20 = {x, 20'd0};
	wire  signed [HW-1:0] err   = x_q20 - st;
	wire  signed [HW+20:0] k_err = err * $signed({1'b0, k});

	logic signed [HW-1:0] k_err_r;

	always_ff @(posedge clk) begin
		if (reset) k_err_r <= '0;
		else       k_err_r <= HW'(k_err >>> 20);
	end

	always_ff @(posedge clk) begin
		if (reset)   st <= '0;
		else if (ce) st <= st + k_err_r;
	end

	// A part-select is unsigned; land it on a signed wire of the same width so
	// the bit pattern survives and the subtraction below is two's complement.
	wire signed [17:0] st_int = st[HW-1:20];

	assign y = HIGHPASS ? (x - st_int) : st_int;

endmodule
