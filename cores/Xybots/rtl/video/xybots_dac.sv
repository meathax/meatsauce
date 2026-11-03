`timescale 1ns/1ps
//============================================================================
//  Xybots video DACs — SP-313 sheet 9: three identical 4-bit binary-weighted
//  current DACs whose shared reference current is set by a fourth, 4-bit
//  intensity ladder.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- the circuit ---------------------------------------------------------
//  Each colour: open-collector U7406 inverters switching R = 620, 1.2K, 2.4K,
//  4.7K (bit 3..bit 0) into a summing node, plus a 74LS260 "all four bits
//  zero" detect.  Intensity: R = 120, 240, 470, 1K into R79 240 and the
//  Q9/Q10 pair, producing ZREF, which sets each colour current source's
//  reference through a 47 Ohm resistor (R118/R119/R120).  The three colour
//  ladders and the three 47 Ohm resistors are component-for-component
//  identical, so ONE transfer serves all three channels, and the output is the
//  PRODUCT of a colour term and an intensity term.
//
//  ---- the transfer --------------------------------------------------------
//  A switched resistor to ground contributes its conductance, so
//
//     fc(n) = ( sum of 1/R over the set bits of n ) / ( sum over all four )
//     fz(I) = the same for the intensity ladder
//     fc(0) = fz(0) = 0                       (the two LS260 zero detects)
//     out8  = round( 255 * fc(nibble) * fz(intensity) )
//
//  The zero detects are modelled as forcing a hard zero.  With the drivers
//  alone the ladder already sinks no current at nibble 0, so the choice is
//  behaviourally free in a digital model; it is stated because the alternative
//  reading (the detect ADDS a current) would make colour 0 brighter than
//  colour 1, which the game's use of entry 0 as black contradicts.
//
//  Neither ladder is exactly binary: 4700/620 = 7.58 rather than 8, and
//  1000/120 = 8.33 rather than 8, so the colour curve sits slightly above
//  MAME's straight n/15 in the low half and slightly below it in the high
//  half, and the intensity curve the other way round.
//
//  ---- MAME ----------------------------------------------------------------
//  MAME's `IRGB_4444` is, measured against two pixel-exact captured frames
//  covering 25 distinct palette words:
//
//      channel = ( (17 * nibble) * (17 * intensity) ) >> 8
//
//  i.e. two straight 4-to-8-bit expansions multiplied and truncated, whose
//  full scale is 254, not 255.  `DAC_MAME_COMPAT = 1` reproduces it bit for
//  bit, which is what a simulation comparing this core against MAME's rendered
//  bitmap wants.  The core itself defaults to the sheet-9 curve; the two differ
//  by at most 4 of 255 over the whole 256-entry table.
//
//  ---- implementation ------------------------------------------------------
//  Not a 256-entry ROM: two 16-entry constant vectors and a multiply, which is
//  what the circuit itself does.  In schematic mode the vectors are
//  round(2^15 * f) and the product is scaled by 255 and rounded; 15 fractional
//  bits is the smallest width at which the integer form reproduces the exact
//  rational rounding for all 256 entries.
//============================================================================

module xybots_dac #(
	parameter bit DAC_MAME_COMPAT = 1'b0
)(
	input  logic [3:0] z,           // Z3..Z0, palette word bits 15:12
	input  logic [3:0] r4,          // R3..R0, bits 11:8
	input  logic [3:0] g4,          // G3..G0, bits  7:4
	input  logic [3:0] b4,          // B3..B0, bits  3:0
	input  logic       blank_n,     // /BLANK: low kills ZREF -> black

	output logic [7:0] red,
	output logic [7:0] green,
	output logic [7:0] blue
);

	// round(2^15 * fc(n)) for the 620 / 1.2K / 2.4K / 4.7K colour ladder,
	// and MAME's 17*n when DAC_MAME_COMPAT is set.  Written as case statements
	// rather than unpacked localparam arrays so that iverilog, Verilator and
	// Quartus 17.0 all elaborate them the same way.
	function automatic logic [16:0] cw_of(input logic [3:0] n);
		if (DAC_MAME_COMPAT) begin
			cw_of = 17'(17 * int'(n));
		end else begin
			case (n)
				4'd0:  cw_of = 17'd0;     4'd1:  cw_of = 17'd2267;
				4'd2:  cw_of = 17'd4439;  4'd3:  cw_of = 17'd6706;
				4'd4:  cw_of = 17'd8878;  4'd5:  cw_of = 17'd11145;
				4'd6:  cw_of = 17'd13317; 4'd7:  cw_of = 17'd15584;
				4'd8:  cw_of = 17'd17184; 4'd9:  cw_of = 17'd19451;
				4'd10: cw_of = 17'd21623; 4'd11: cw_of = 17'd23890;
				4'd12: cw_of = 17'd26062; 4'd13: cw_of = 17'd28329;
				4'd14: cw_of = 17'd30501; default: cw_of = 17'd32768;
			endcase
		end
	endfunction

	// round(2^15 * fz(I)) for the 120 / 240 / 470 / 1K intensity ladder
	function automatic logic [16:0] zw_of(input logic [3:0] i);
		if (DAC_MAME_COMPAT) begin
			zw_of = 17'(17 * int'(i));
		end else begin
			case (i)
				4'd0:  zw_of = 17'd0;     4'd1:  zw_of = 17'd2097;
				4'd2:  zw_of = 17'd4461;  4'd3:  zw_of = 17'd6558;
				4'd4:  zw_of = 17'd8737;  4'd5:  zw_of = 17'd10833;
				4'd6:  zw_of = 17'd13198; 4'd7:  zw_of = 17'd15295;
				4'd8:  zw_of = 17'd17473; 4'd9:  zw_of = 17'd19570;
				4'd10: zw_of = 17'd21935; 4'd11: zw_of = 17'd24031;
				4'd12: zw_of = 17'd26210; 4'd13: zw_of = 17'd28307;
				4'd14: zw_of = 17'd30671; default: zw_of = 17'd32768;
			endcase
		end
	endfunction

	localparam int         MULT   = DAC_MAME_COMPAT ? 1 : 255;
	localparam int         SH     = DAC_MAME_COMPAT ? 8 : 30;
	localparam logic [48:0] ROUNDC = DAC_MAME_COMPAT ? 49'd0 : (49'd1 << 29);

	function automatic logic [7:0] xfer(input logic [3:0] n, input logic [3:0] i);
		// The shifted product is 8-bit by construction — 255 * 2^30 >> 30 in
		// schematic mode, 255*255 >> 8 in MAME mode — so the cast is exact.
		/* verilator lint_off UNUSEDSIGNAL */
		logic [48:0] prod;
		/* verilator lint_on UNUSEDSIGNAL */
		prod = (49'(cw_of(n)) * 49'(zw_of(i)) * 49'(MULT) + ROUNDC) >> SH;
		xfer = 8'(prod);
	endfunction

	always_comb begin
		if (!blank_n) begin
			red   = 8'h00;
			green = 8'h00;
			blue  = 8'h00;
		end else begin
			red   = xfer(r4, z);
			green = xfer(g4, z);
			blue  = xfer(b4, z);
		end
	end

endmodule
