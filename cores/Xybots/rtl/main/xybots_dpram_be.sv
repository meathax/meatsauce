`timescale 1ns/1ps
//============================================================================
//  Generic 16-bit dual-port block RAM with independent byte write enables.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Used twice on the main board:
//    * the 16 KB video RAM at 14J/14E (`AW = 13`, 8 K words), where the two
//      8464D70 SRAMs take independent /WE strobes so byte writes on either
//      lane are honoured;
//    * the 2 KB colour RAM at 17J/17K (`AW = 10`, 1 K words).
//
//  Port A is the 68000 side (read + byte writes), port B is the video side
//  (read only).  Both are registered-output, which is what an M10K infers and
//  what makes the read data settle a full clk_sys before /DTACK is asserted.
//  Two byte-wide arrays rather than one 16-bit array with bit-select writes:
//  it is the textbook byte-enable inference pattern for Quartus.
//============================================================================

module xybots_dpram_be #(
	parameter int AW = 13
)(
	input  logic          clk,

	// port A — 68000
	input  logic [AW-1:0] a_addr,
	input  logic [15:0]   a_din,
	input  logic          a_we_hi,   // D15:8
	input  logic          a_we_lo,   // D7:0
	output logic [15:0]   a_dout,

	// port B — video (read only)
	input  logic [AW-1:0] b_addr,
	output logic [15:0]   b_dout
);

	localparam int WORDS = 1 << AW;

	logic [7:0] mem_hi [0:WORDS-1];
	logic [7:0] mem_lo [0:WORDS-1];

`ifndef ALTERA_RESERVED_QIS
	// Sim-only zero fill so iverilog/verilator never see X out of an unwritten
	// location.  Quartus zeroes M10K contents at configuration anyway.
	initial begin
		for (int i = 0; i < WORDS; i++) begin
			mem_hi[i] = '0;
			mem_lo[i] = '0;
		end
	end
`endif

	always_ff @(posedge clk) begin
		if (a_we_hi) mem_hi[a_addr] <= a_din[15:8];
		if (a_we_lo) mem_lo[a_addr] <= a_din[7:0];
		a_dout <= {mem_hi[a_addr], mem_lo[a_addr]};
		b_dout <= {mem_hi[b_addr], mem_lo[b_addr]};
	end

endmodule
