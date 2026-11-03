`timescale 1ns/1ps
//============================================================================
//  Xybots watchdog — SP-313 sheet 2 (1A LS00, 3A LS90, 4A LS04).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Gate for gate:
//
//    1A LS00   pin 4 = WDPR, pin 5 = /WDOG -> pin 6.
//              WDPR is pulled to +5 V by R112; **JP2 shorts WDPR to ground**,
//              which nails 1A/6 high and so holds the counter cleared forever
//              = the watchdog is disabled.
//    3A LS90   CP0 (14) = /VBLANK        — one count per frame, NEGATIVE edge,
//                                          i.e. at the START of vertical blank
//              CP1 (1)  = QA             — the ordinary BCD cascade
//              R0(1),R0(2) (2,3) = 1A/6  — a /WDOG write clears the count to 0
//              R9(1),R9(2) (6,7) = POR   — power-on parks the count at 9
//    4A LS04   (13->12)  /RESET = ~QD
//
//  QD is high for BCD 8 and 9, so /RESET asserts after **8 VBLANKs without a
//  /WDOG write** (~133 ms) and stays asserted for **two frames** before the
//  counter rolls 9 -> 0 and releases it.  At power-up R9 holds the count at 9,
//  so /RESET is asserted out of the box; when POR releases, the next /VBLANK
//  edge rolls 9 -> 0 and the board starts.
//
//  On a real LS90 the R9 pair overrides the R0 pair, and both are LEVEL master
//  resets that override the clock — that ordering is reproduced below.
//
//  **MAME says** `WATCHDOG_TIMER(config, "watchdog")` with default timing: the
//  8-frame period, the 2-frame pulse and the park-at-9 power-up are not
//  modelled there.
//
//  What /RESET reaches is deliberately narrow: the 68000's RESET+HALT
//  pins, the 4B LS74 EEPROM unlock flip-flop's /CLR, and the 2A LS08 that gates
//  the EEPROM /OE.  It does NOT reach the slapstic, SYNGEN, the audio connector
//  or any video sheet.
//============================================================================

module xybots_watchdog #(
	// JP2 fitted (WDPR shorted to ground) -> the watchdog never fires.  The
	// shipped board has JP2 OPEN, so the default is 0.
	parameter bit JP2 = 1'b0
)(
	input  logic clk,
	input  logic por,          // power-on reset, active high (sheet 1, 11A LS14)
	input  logic vblank_start, // 1-clk pulse at the assertion edge of /VBLANK
	input  logic wdog_clr,     // 1-clk pulse: any write to 0x806A00 (/WDOG)

	output logic reset_n,      // the /RESET net, active low
	// 3A QD..QA; diagnostic output, no consumer in the core.
	output logic [3:0] count
);

	// 1A LS00 (4 = WDPR, 5 = /WDOG -> 6) drives the R0 pair.  With JP2 fitted
	// WDPR = 0 so the output is stuck high and R0 is permanently asserted.
	wire r0 = JP2 ? 1'b1 : wdog_clr;

	always_ff @(posedge clk) begin
		if (por)               count <= 4'd9;   // R9 pair, highest priority
		else if (r0)           count <= 4'd0;   // R0 pair
		else if (vblank_start) count <= (count == 4'd9) ? 4'd0 : count + 4'd1;
	end

	assign reset_n = ~count[3];                 // 4A LS04, /RESET = ~QD

endmodule
