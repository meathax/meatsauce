`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Board watchdog — 74LS90 at CPU-board position 7A (SP-251 sheet 3A / PDF p5).
//
// KNOWN (traced on sheet 3A):
//   * 74LS90 wired as a BCD divide-by-ten: QA (pin 12) is jumpered back into
//     input B (pin 1), so QA..QD form a single 0..9 decade.
//   * Clock is input A (pin 14) = net `128V`, arriving from the video board on
//     J17 pin 43.  LS90 input A is NEGATIVE-edge triggered.
//   * R0(1)/R0(2) (pins 2,3) are tied together to net `WDOG`, the $1900-$19FF
//     write decode (`WDCLR`).  An active-high pulse clears the count to 0.
//   * R9(1)/R9(2) (pins 6,7) are tied to the power-on / manual reset node, so
//     power-on forces count 9 -> QD high -> reset asserted.
//   * QD (pin 11) -> LS04 6B pin 13 -> pin 12 = `/RESET`, driving 68B09E pin 37,
//     the three CPU-board output latches (LS273 6H OUT0, 2C/D STATWR,
//     10L OUT1) and a J17 pin toward the video board.  This is a BOARD-WIDE
//     reset, not CPU-only.
//
// INFERRED (arithmetic on the KNOWN wiring, never measured):
//   * `128V` is the MSB of the free-running 8-bit V counter, so one falling
//     edge per 256-line frame (16.384 ms) -> one watchdog count per frame.
//   * In LS90 BCD mode QD is high for counts 8 and 9, so the watchdog fires
//     after COUNT_TO_FIRE = 8 frames (~131 ms) without a WDCLR write, and
//     naturally releases 2 counts later when the decade wraps to 0.
//
// DIVERGENCE FROM MAME 0.289: irobot.cpp maps 0x1900-0x19ff as `nopw()` and
// models no watchdog at all.  A faithful core therefore resets in cases MAME
// silently tolerates.  Keep COUNT_TO_FIRE parameterized until a PCB check.
//
// HYPOTHESIS: RESET_MIN_CYCLES has no hardware counterpart — on the real board
// the 2-count (2-frame) QD window is inherently long.  It exists only so the
// output remains a usable synchronous CPU reset if a caller drives `tick_128v`
// from something faster than a frame; default 16 clk is far below 2 frames and
// so is invisible with the hardware-accurate connection below.
//
// INTEGRATED CONNECTION (rtl/irobot_board.sv):
//   .clk        ( clk_12m096 )              // 12.096 MHz CPU domain
//   .reset      ( power_on_reset )          // R9 set-to-9 node; NOT the module's
//                                           //   own reset_out (no loop)
//   .wdclr      ( cpu_write && addr[15:8]==8'h19 ) // $1900-$19FF write strobe,
//                                           //   1 clk wide, CPU-domain
//   .tick_128v  ( scanline[7] )             // net 128V: MSB of the video V
//                                           //   counter, synchronised into the
//                                           //   CPU clock domain by the caller
//   .reset_out  ( -> board-wide reset: OR into 6809 /RESET and into the CLR of
//                    the OUT0 / STATWR / OUT1 latches )
// Drive `tick_128v` as a LEVEL, not a strobe; the falling edge is detected here,
// matching the LS90's negative-edge input A.
//
module irobot_watchdog #(
	parameter int COUNT_TO_FIRE     = 8,   // LS90 BCD QD rises at count 8 (INFERRED)
	parameter int COUNT_MODULO      = 10,  // BCD decade (KNOWN: QA fed back to B)
	parameter int RESET_MIN_CYCLES  = 16   // minimum reset_out width in clk (HYPOTHESIS)
) (
	input  logic clk,        // 12.096 MHz CPU domain
	input  logic reset,      // power-on / manual reset: LS90 R9 set-to-9
	input  logic wdclr,      // $1900-$19FF write strobe: LS90 R0, clears count
	input  logic tick_128v,  // net 128V level; counts on its falling edge
	output logic reset_out   // active-high board-wide reset (LS90 QD)
);
	localparam int CW = (COUNT_MODULO <= 2) ? 1 : $clog2(COUNT_MODULO);
	localparam int SW = (RESET_MIN_CYCLES <= 1) ? 1 : $clog2(RESET_MIN_CYCLES + 1);

	logic [CW-1:0] cnt;
	logic          tick_q;
	logic [SW-1:0] stretch;
	logic          fire;

	// LS90 QD: high for the top two counts of the decade.
	assign fire = (cnt >= CW'(COUNT_TO_FIRE));

	always_ff @(posedge clk) begin
		if (reset) begin
			cnt    <= CW'(COUNT_MODULO - 1);  // R9 forces count 9 -> QD high
			tick_q <= tick_128v;
		end else begin
			tick_q <= tick_128v;
			if (wdclr) cnt <= '0;                                  // R0 clear
			else if (tick_q & ~tick_128v)                          // falling 128V
				cnt <= (cnt == CW'(COUNT_MODULO - 1)) ? CW'(0) : cnt + CW'(1);
		end
	end

	// Width guarantee only; never shortens the hardware QD window.
	always_ff @(posedge clk) begin
		if (reset)          stretch <= SW'(RESET_MIN_CYCLES);
		else if (fire)      stretch <= SW'(RESET_MIN_CYCLES);
		else if (|stretch)  stretch <= stretch - SW'(1);
	end

	assign reset_out = fire | (|stretch);
endmodule
