`timescale 1ns/1ps
//============================================================================
//  Xybots /DTACK generator — SP-313 sheet 2 (5A LS163A + 7B 74S74 + 1B LS02).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Gate for gate:
//
//  Non-video path — 5A LS163A, a SYNCHRONOUS-clear 4-bit binary counter:
//      CK   (2)  = VIDCLK (= the 68000 clock, 7.15909 MHz)
//      /CLR (1)  = 2A LS08 (1 = /VRAM, 2 = AS -> 3)  = /VRAM & AS
//                  -> the counter is held at 0 whenever there is no bus cycle
//                     AND during every video-RAM cycle.
//      /LD  (9)  = QD (11)                -> reload whenever QD = 0
//      A(3)=PR1=1  B(4)=/EEROM  C(5)=PR1=1  D(6)=PR1=1
//                  -> load 0b1111 = 15 normally, 0b1101 = 13 for /EEROM
//      ENT  (10) = /VPA        -> RCO forced low during an autovector cycle
//      ENP  (7)  = /DTACK      -> counting stops once DTACK is asserted
//      RCO  (15) = QA&QB&QC&QD&ENT
//
//  So a normal cycle loads 15 on the first VIDCLK edge after AS and RCO (hence
//  /DTACK) is immediate -> a 4-clock 68000 bus cycle, no wait states.  An
//  /EEROM cycle loads 13 and has to count 14, 15, which is **two extra VIDCLK
//  wait states** (~279 ns) for the slow X2804A.
//
//  Video path — 7B 74S74:
//      D    (12) = /VRAM
//      CK   (11) = VRAC2
//      /PRE (10) = AS          -> with no bus cycle Q is preset to 1
//      /CLR (13) = PR3 (tied inactive)
//      /Q   (8)  = VDTACK
//  With AS inactive the preset holds Q = 1 so VDTACK = 0.  During a bus cycle
//  the next VRAC2 edge clocks /VRAM into Q; a video-RAM access (/VRAM = 0)
//  gives Q = 0 -> VDTACK = 1.  The CPU is DTACKed only when its slot in the
//  four-phase video-RAM multiplex (VRAC = 3) comes round, so a VRAM
//  access costs 0..3 extra VIDCLKs depending on where in the phase it started.
//
//      /DTACK = 1B LS02 (2 = RCO, 3 = VDTACK -> 1) = ~(RCO | VDTACK)
//
//  Note what is NOT in the equation: no strobe, no chip select, nothing that
//  says "this address exists".  Reads of write-only strobes, the three
//  unconnected LS138 outputs (0x806C00 / 0x806D00 / 0x806F00) and the whole
//  undecoded 0x807000 page all terminate exactly like a ROM cycle.  A 68000
//  on this board can never hang on an address.
//============================================================================

module xybots_dtack
(
	input  logic clk,       // clk_sys
	input  logic ce_7m,     // VIDCLK enable (clk_sys / 8)
	input  logic reset,     // active high; parks the counter at 0

	input  logic as,        // active-high copy of /AS
	input  logic vram_n,    // /VRAM
	input  logic eerom_n,   // /EEROM
	input  logic vpa_n,     // /VPA  -> 5A ENT
	input  logic vrac2,     // sheet-4/5 VRAC2, the 7B clock (level; edge used)

	output logic dtack,     // active HIGH (= ~/DTACK) for the CPU wrapper
	// The next three are diagnostic output; no consumer in the core.
	output logic vdtack,    // 7B /Q
	output logic rco,       // 5A RCO
	output logic [3:0] wcnt // 5A QD..QA
);

	// ---- 5A LS163A -------------------------------------------------------
	wire clr_n = vram_n & as;                 // 2A LS08
	wire ld_n  = wcnt[3];                     // /LD = QD
	wire ent   = vpa_n;
	wire enp   = ~dtack;                      // ENP = /DTACK

	assign rco = (&wcnt) & ent;

	always_ff @(posedge clk) begin
		if (reset) begin
			wcnt <= 4'd0;
		end else if (ce_7m) begin
			if (!clr_n)      wcnt <= 4'd0;                     // synchronous clear
			// {QD,QC,QB,QA} = {D,C,B,A} = {1, 1, /EEROM, 1}
			else if (!ld_n)  wcnt <= {2'b11, eerom_n, 1'b1};
			else if (ent & enp) wcnt <= wcnt + 4'd1;
		end
	end

	// ---- 7B 74S74 --------------------------------------------------------
	// /PRE = AS is asynchronous on the real part.  Modelled as a set on
	// clk_sys, which is an eighth of a VIDCLK, so a cycle that ends between
	// VRAC2 edges still drops VDTACK before the CPU can look.
	logic q7b, vrac2_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			q7b     <= 1'b1;
			vrac2_d <= 1'b0;
		end else begin
			vrac2_d <= vrac2;
			if (!as)                     q7b <= 1'b1;   // /PRE = AS
			else if (vrac2 & ~vrac2_d)   q7b <= vram_n; // rising edge of VRAC2
		end
	end
	assign vdtack = ~q7b;

	// ---- 1B LS02 ---------------------------------------------------------
	assign dtack = rco | vdtack;

endmodule
