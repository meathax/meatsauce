`timescale 1ns/1ps
//============================================================================
//  Batman video DAC: the three R2R 1K/2K ladders R11/R12/R13, the 74LS260
//  pen-zero NORs at 3A/B and 3B/C and the 7406 black clamp at 3C/D
//  (schematic page 43).
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_dac.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Each gun is a 6-bit ladder whose LSB is the shared intensity bit I
//  (colour-RAM bit 15): gun = {channel[4:0], I}, expanded to 8 bits the way
//  MAME does.  A 74LS260 NOR over the five upper bits of each gun drives a
//  7406 that pulls the gun to black when they are all zero; I is not in the
//  NOR, so {0, I=1} is black on the board.  MAME has no clamp and shows that
//  code as 4/255; BLACK_CLAMP = 0 reproduces MAME.
//============================================================================

module batman_dac #(
	parameter bit BLACK_CLAMP = 1'b1
)(
	input  logic [15:0] colour,        // latched colour word
	output logic [5:0]  code_r,        // the six bits driving the red ladder
	output logic [5:0]  code_g,
	output logic [5:0]  code_b,
	output logic [7:0]  red,
	output logic [7:0]  green,
	output logic [7:0]  blue
);

	wire       rgb0 = colour[15];      // `I`, the shared LSB tap
	wire [4:0] r5   = colour[14:10];
	wire [4:0] g5   = colour[9:5];
	wire [4:0] b5   = colour[4:0];

	assign code_r = {r5, rgb0};
	assign code_g = {g5, rgb0};
	assign code_b = {b5, rgb0};

	// MAME's pal6bit: (v << 2) | (v >> 4), equal to round(255 * v / 63).
	function automatic logic [7:0] pal6bit(input logic [5:0] v);
		pal6bit = {v, v[5:4]};
	endfunction

	// The LS260 sees the five upper bits only; RGB0 is not in the NOR.
	wire clamp_r = BLACK_CLAMP & (r5 == 5'd0);
	wire clamp_g = BLACK_CLAMP & (g5 == 5'd0);
	wire clamp_b = BLACK_CLAMP & (b5 == 5'd0);

	assign red   = clamp_r ? 8'd0 : pal6bit(code_r);
	assign green = clamp_g ? 8'd0 : pal6bit(code_g);
	assign blue  = clamp_b ? 8'd0 : pal6bit(code_b);

endmodule
