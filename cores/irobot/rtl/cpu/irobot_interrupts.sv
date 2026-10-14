`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Main CPU interrupt sources.
//
// IRQ: SP-251 sheet 5A, LS74 at 5C.  The flip-flop's D input is 32V (J17
// pin 46) and its clock is 16V (J17 pin 45), so the raster interrupt is 32V
// *sampled on the rising edge of 16V*, not the 32V level itself.  16V rises
// every 32 lines at V mod 32 == 16, so the request asserts on lines 48, 112,
// 176 and 240 and is dropped again on 16, 80, 144 and 208 when the sample
// sees 32V low.  The CLR input is the $1100 write (IRQEN), which ends the
// request early once the handler has run.  MAME's driver models the request
// as the raw 32V level from lines 32/96/160/224; that is sixteen lines early,
// and with the board's VBLANK on lines 232..255 it leaves no interrupt inside
// VBLANK.  The ROM's handler at $6006 tests STATRD bit 7 immediately, so on
// the board the line-240 request is the one that sees VBLANK and performs the
// per-frame work.  Evidence: .mister/evidence/plan-audit-20260908/vblank-gate.
//
// FIRQ: mathbox completion latches the request; $1A00 clears it.
module irobot_interrupts (
	input logic clk, input logic reset,
	// Only V bit 5 (32V) and the low five bits (the 16V edge) matter to the
	// flip-flop; the full counter is kept on the port to match the board net.
	/* verilator lint_off UNUSEDSIGNAL */
	input logic scanline_start, input logic [7:0] scanline,
	/* verilator lint_on UNUSEDSIGNAL */
	input logic irq_clear, input logic math_done, input logic firq_clear,
	output logic irq_n, output logic firq_n
);
	logic irq_latch,firq_latch;
	always_ff @(posedge clk) begin
		if(reset) begin irq_latch<=0;firq_latch<=0; end
		else begin
			// Rising edge of 16V: V mod 32 == 16.  Sample 32V (V bit 5).
			if(scanline_start && scanline[4:0]==5'd16) irq_latch<=scanline[5];
			if(irq_clear) irq_latch<=0;
			if(math_done) firq_latch<=1;
			if(firq_clear) firq_latch<=0;
		end
	end
	assign irq_n=~irq_latch; assign firq_n=~firq_latch;
endmodule
