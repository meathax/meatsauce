`timescale 1ns/1ps
//============================================================================
//  Xybots control-panel and status ports — SP-313 sheet 4 (18F, 21E, 18J).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- /SW, 0x806100 -------------------------------------------------------
//  18F LS244B drives the HIGH byte and 21E LS244B the LOW byte; both /1G and
//  /2G on both parts are `/SW`, so the port is a full 16-bit read and the game
//  reads it as a word (`move.w $e100.w,d1`, pc 0x103E8).  Every switch has a
//  470 R pull-up, a 0.1 uF cap and a 1 K series resistor into the buffer, so
//  every bit is **active low**.
//
//    D15 P1 UP     D14 P1 DOWN   D13 P1 LEFT   D12 P1 RIGHT
//    D11 P1 TWIST LEFT           D10 P1 TWIST RIGHT
//    D9  P1 FIRE   D8  P1 START
//    D7  P2 UP     D6  P2 DOWN   D5  P2 LEFT   D4  P2 RIGHT
//    D3  P2 TWIST LEFT           D2  P2 TWIST RIGHT
//    D1  P2 FIRE   D0  P2 START
//
//  The twist grip is TWO ORDINARY SWITCHES, not a quadrature encoder, and each
//  player's FIRE is two switches wired in parallel (S11A+S11B / S21A+S21B) —
//  so all ten P1/P2 bits are independent and must stay independent (the self
//  test's control screen watches each one).  The `CLK0/DIR0/...` net names on
//  the DC connector are vestigial; sheet 10 labels the same pins START, FIRE,
//  TWIST RT, TWIST LT, RIGHT, LEFT, DOWN, UP.
//  **MAME says** FFE100 bit 0 = START2 ... bit 15 = P1 JOYSTICK UP — an exact
//  match, including the low byte = player 2 split.
//
//  ---- /SYSIN, 0x806200 ----------------------------------------------------
//  18J LS244A, both enables = `/SYSIN`, drives the HIGH byte only:
//    D8  /SELFTEST     D9  /AUDBUSY (SCOM 20E BUSY)
//    D10 256H          D11 VBLANK
//    D12 SW8  D13 SW9  D14 SW10  D15 SW11   (connector SWB, pins 3-6)
//  **Nothing drives D0B-D7B during a /SYSIN read** — the low byte floats, and
//  the game only ever reads this port as a byte at the EVEN address
//  (`btst.b #n,$e200.w`), so it never looks at the low half.
//
//  Two schematic-vs-MAME points:
//   * **D12-D15 are four real switch inputs** on connector SWB that MAME
//     declares `IPT_UNUSED`.  They are exposed here as inputs and default to
//     inactive (reading 1), so the core matches MAME unless a user wires them.
//   * **256H (D10) is never tested by the program.** MAME approximates it by
//     XORing 0x0400 on every read of the port; this core drives the real 256H
//     from the video counter, because nothing observable depends on it and the
//     hardware signal is free.
//
//  /AUDBUSY reads 1 = "the sound CPU has taken the last command" and 0 = "a
//  command is still pending"; the game refuses to write /AUDWR while it is 0
//  (pc 0xC4C / 0xC8A).  The JSA mailbox signal `snd_m2s_ready` is high while a
//  command is PENDING, i.e. it is the complement of /AUDBUSY, so D9 inverts it.
//
//  This module is pure combinational packing: no clock, no state.
//============================================================================

module xybots_inputs
(
	// ---- /SW, active-high "pressed" inputs; inverted into the port here ----
	input  logic p1_up, p1_down, p1_left, p1_right,
	input  logic p1_twist_l, p1_twist_r, p1_fire, p1_start,
	input  logic p2_up, p2_down, p2_left, p2_right,
	input  logic p2_twist_l, p2_twist_r, p2_fire, p2_start,

	// ---- /SYSIN ----
	input  logic self_test,     // 1 = the self-test switch is ON  -> D8 = 0
	input  logic snd_m2s_ready, // JSA main_to_sound_ready (1 = command pending)
	input  logic h256,          // 256H straight off the SYNGEN counter
	input  logic vblank,        // active high
	input  logic sw8, sw9, sw10, sw11,   // SWB-3..6, active-high "pressed"

	output logic [15:0] sw,     // 0x806100, full word
	output logic [15:0] sysin   // 0x806200; D7:0 floats, modelled as 1s
);

	assign sw = ~{ p1_up, p1_down, p1_left, p1_right,
	               p1_twist_l, p1_twist_r, p1_fire, p1_start,
	               p2_up, p2_down, p2_left, p2_right,
	               p2_twist_l, p2_twist_r, p2_fire, p2_start };

	assign sysin = { ~sw11, ~sw10, ~sw9, ~sw8,     // D15..D12  SWB
	                  vblank,                       // D11 VBLANK, active high
	                  h256,                         // D10 256H,   active high
	                 ~snd_m2s_ready,                // D9  /AUDBUSY
	                 ~self_test,                    // D8  /SELFTEST
	                  8'hFF };                      // D7:0 not driven

endmodule
