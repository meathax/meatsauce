`timescale 1ns/1ps
//============================================================================
//  Xybots interrupt encoder — SP-313 sheet 2 (1B LS02, 10A LS20, 4A LS04,
//  3B LS00, 1C 74S74, 10C LS00).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Gate for gate:
//
//   1. 1B LS02 (11 = VBLANK, 12 = /HBLANK -> 13) = ~VBLANK & HBLANK
//   2. 10A LS20 NAND{ that, 4V, 2V, 1V } -> 4A LS04 (9->8)
//      = a level that is high exactly while  V[2:0] == 7 & HBLANK & ~VBLANK
//   3. 3B LS00 (12 = VIRQ, 13 = that -> 11)      -> /PRE of the latch
//   4. 1C 74S74 as an S/R latch: D = CK = PR1 (it never clocks),
//      /PRE = 3B/11, /CLR = /VIDACK, Q -> 10C LS00 pin 2
//   5. 10C LS00 (1 = /IPL1, 2 = Q -> 3) = /IPL0
//
//  ---- VIRQ is programmable, and that is the biggest schematic-vs-MAME
//       difference in the whole core ----------------------------------------
//  `VIRQ` is not a raster signal.  SP-313 sheet 7, 6D LS174E (CK = 4H) latches
//  **SCRAMD10 -> VIRQ**, i.e. bit 10 of the ALPHA tile word being fetched.  So
//  the game arms an interrupt on any tile row it likes by setting bit 10 of the
//  alpha word that is fetched during horizontal blanking, and the sheet-2 gate
//  above fires it at the end of every 8th scanline where that bit is set.
//  MAME instead does `screen_vblank() -> ASSERT_LINE M68K_IRQ_1`, one IRQ per
//  frame.  In attract and in play the game keeps exactly ONE armed word — row
//  29, column 42 — so the two models coincide at ~line 239; in SELF TEST the
//  character-set and RAM-test screens set bit 10 in thousands of visible words
//  and real hardware takes VIRQ many times per frame while MAME never does.
//  This module implements the schematic.  `virq` is the latched alpha bit 10
//  from the video timing block; the gating with V[2:0]/HBLANK/VBLANK is here
//  because sheet 2 is where it is drawn.
//
//  ---- the encoder, and why it matters -----------------------------------
//  IPL2 is tied inactive (16A pin 23 = PR2), and /IPL1 comes straight from the
//  SCOM's active-low FULL output.  10C LS00 *encodes* rather than prioritises:
//
//      /IPL1  Q(video)   /IPL0   68000 level
//        0       x         1        2   (sound)
//        1       1         0        1   (video)
//        1       0         1        0   (none)
//
//  i.e. **while the sound interrupt is asserted the video interrupt is
//  invisible to the CPU**.  MAME drives two independent input lines.  The
//  level seen by the CPU is the same, but the encoder is what the board does
//  and it is what a cycle-accurate core must reproduce.
//
//  IRQ2 has no acknowledge strobe anywhere on sheets 2-3: the SCOM's FULL flag
//  is cleared by the /AUDRD read itself, which is why `sound_irq` here is a
//  pure level from the JSA mailbox.
//============================================================================

module xybots_irq
(
	input  logic       clk,
	// POWER-UP ONLY.  The 1C 74S74 has no reset input on the board: its /CLR is
	// `/VIDACK` and nothing else, so a watchdog timeout or a 68000 RESET
	// instruction leaves a pending IRQ1 pending (the CPU comes out of reset with
	// the SR mask at 7 anyway, and the handler's first act is the /VIDACK
	// write).  Drive this from `init_reset` alone, not from the /RESET net.
	input  logic       reset,

	// video side
	input  logic       virq,        // 6D LS174E pin 2: latched alpha word bit 10
	input  logic [2:0] v,           // 4V, 2V, 1V
	input  logic       hblank,      // active high
	input  logic       vblank,      // active high

	// CPU side
	input  logic       vidack_wr,   // 1-clk pulse: any write to 0x806B00
	input  logic       sound_irq,   // level from the JSA mailbox (SCOM /FULL low)

	output logic [2:0] ipl,         // {IPL2,IPL1,IPL0}, active low, 111 = none
	// 1C 74S74 Q; diagnostic output, no consumer in the core.
	output logic       irq1_pending
);

	// 1B LS02 + 10A LS20 + 4A LS04
	wire hb_window = hblank & ~vblank;
	wire virq_gate = hb_window & (v == 3'd7);

	// 3B LS00 -> /PRE.  The latch is level-set: while VIRQ and the window are
	// both true the preset holds Q at 1, so a /VIDACK write that lands in the
	// same window cannot clear it (both /PRE and /CLR low on a 74S74 forces
	// Q = /Q = 1; on release the preset wins here because it is a level, not an
	// edge).  That is what stops a request being lost.
	wire pre_n = ~(virq & virq_gate);

	always_ff @(posedge clk) begin
		if (reset)          irq1_pending <= 1'b0;
		else if (!pre_n)    irq1_pending <= 1'b1;   // /PRE
		else if (vidack_wr) irq1_pending <= 1'b0;   // /CLR = /VIDACK
	end

	// 10C LS00: /IPL0 = ~( /IPL1 & Q ).  /IPL1 = ~sound_irq.  IPL2 tied high.
	wire ipl1_n = ~sound_irq;
	wire ipl0_n = ~(ipl1_n & irq1_pending);
	assign ipl = {1'b1, ipl1_n, ipl0_n};

endmodule
