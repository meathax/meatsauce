`timescale 1ns/1ps
//============================================================================
//  Xybots colour-RAM read path and video output registers — SP-313 sheet 9
//  (17J/17K 2K8-100A used as 1K x 16, 18L and 19L LS273H).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  The colour RAM array itself lives in `rtl/main/xybots_main_bus.sv`, next to
//  the 68000 port that writes it; this module is the video half: it drives
//  that block's read-only port with the GPC's address and captures the word
//  into the two output registers.
//
//  18L / 19L are clocked by 8M 74S32 (12 = CRAMD, 13 = /7M -> 11).  Outside a
//  CPU palette cycle CRAMD is low, so the clock is simply /7M -- one register
//  stage per pixel, modelled on ce_7m.  Layout, straight off the wiring and
//  identical to MAME's IRGB_4444:
//
//      15..12 Z3..Z0   11..8 R3..R0    7..4 G3..G0    3..0 B3..B0
//
//  `/BLANK` is not handled here: on the board it is wired into the ZREF
//  generator, so it kills the shared reference current rather than gating the
//  palette output.  It reaches xybots_dac instead.
//============================================================================

module xybots_cram (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- from the GPC ----
	input  logic  [9:0] cram_a,

	// ---- xybots_main_bus colour-RAM video port (BRAM, latency 1) ----
	output logic  [9:0] cram_vaddr,
	input  logic [15:0] cram_vdata,

	// ---- 18L / 19L LS273H ----
	output logic  [3:0] z,
	output logic  [3:0] r,
	output logic  [3:0] g,
	output logic  [3:0] b
);

	assign cram_vaddr = cram_a;

	always_ff @(posedge clk) begin
		if (reset) begin
			z <= '0; r <= '0; g <= '0; b <= '0;
		end else if (ce_7m) begin
			z <= cram_vdata[15:12];
			r <= cram_vdata[11:8];
			g <= cram_vdata[7:4];
			b <= cram_vdata[3:0];
		end
	end

endmodule
