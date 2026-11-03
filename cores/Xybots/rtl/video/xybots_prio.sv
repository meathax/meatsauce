`timescale 1ns/1ps
//============================================================================
//  Xybots priority network — SP-313 sheet 8: 9C LS10 (PRIEN), 12J 74S85 with
//  its cascade trick, 11K 74S157 (the P bus) and the 12K + 14M LS32 gates
//  (the M bus).  Pure combinational logic, exactly as drawn.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- everything from the line buffer is INVERTED sense -------------------
//  LBPIX = ~pen, LBCOL = ~colour, LBPRI = ~priority (= MAME's `mopriority`).
//  All three read 4'hF where no motion object covers the pixel, which is what
//  makes "M bus == 8'hFF" mean "no motion object here".
//
//  ---- 12J is a 74S85, not a PAL ------------------------------------------
//  A = LBPRI, B = PFCOL, A<BI = A>BI = GND and A=BI = PRIEN; the only output
//  used is A>BO = PF/MO.  A 74S85 whose three cascade inputs are all low
//  drives BOTH A>BO and A<BO high on A == B, so:
//
//     PRIEN = 1  ->  PF/MO = (LBPRI >  PFCOL)
//     PRIEN = 0  ->  PF/MO = (LBPRI >= PFCOL)
//
//  which is the pair of equations MAME uses.  PF/MO high means the PLAYFIELD
//  wins.  The comparator below is written as the device's own truth table,
//  cascade rows included, rather than as those two equations, so the cascade
//  state is modelled instead of assumed.
//============================================================================

module xybots_prio (
	// playfield, from xybots_pf via 13K
	input  logic [3:0] pfpix,
	input  logic [3:0] pfcol,

	// motion objects, from the sheet-8 line buffers (inverted sense)
	input  logic [3:0] lb_pix,
	input  logic [3:0] lb_col,
	input  logic [3:0] lb_pri,

	output logic       prien,       // 9C LS10 pin 8
	output logic       pf_mo,       // 12J 74S85 pin 5 (A>BO): 1 = playfield wins
	output logic [7:0] p_bus,       // GPC P7..P0
	output logic [7:0] m_bus        // GPC M7..M0
);

	// ---- 9C LS10: a 3-input NAND of LBPIX3, LBPIX2, LBPIX1 ----------------
	assign prien = ~(lb_pix[3] & lb_pix[2] & lb_pix[1]);

	// ---- 12J 74S85 ---------------------------------------------------------
	// The structural device, so that the cascade state is modelled and not
	// assumed.  Inputs: A, B, and {A>BI, A<BI, A=BI} = {0, 0, PRIEN}.
	logic gt_o, lt_o, eq_o;
	always_comb begin
		if (lb_pri > pfcol) begin
			gt_o = 1'b1; lt_o = 1'b0; eq_o = 1'b0;
		end else if (lb_pri < pfcol) begin
			gt_o = 1'b0; lt_o = 1'b1; eq_o = 1'b0;
		end else begin
			// A == B: the outputs follow the cascade inputs.  With A>BI = 0 and
			// A<BI = 0 the 74S85 gives {1,1,0} when A=BI is also 0, and {0,0,1}
			// when A=BI is high.
			gt_o = ~prien; lt_o = ~prien; eq_o = prien;
		end
	end
	assign pf_mo = gt_o;

	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_85 = |{lt_o, eq_o};     // A<BO (pin 7) and A=BO (pin 6) are NC
	/* verilator lint_on UNUSEDSIGNAL */

	// ---- 11K 74S157 --------------------------------------------------------
	// SEL = 8M 74S32 ( PF/MO , 10E 74S00(PRIEN, 11J 74S04(LBCOL3)) )
	//     = PF/MO | ~(PRIEN & ~LBCOL3)
	// SEL = 1 selects the B inputs, i.e. PFPIX.
	wire sel_11k = pf_mo | ~(prien & ~lb_col[3]);
	assign p_bus = {pfcol, (sel_11k ? pfpix : lb_col)};

	// ---- 12K + 14M LS32: every M bit ORed with PF/MO -----------------------
	assign m_bus = {lb_col, lb_pix} | {8{pf_mo}};

endmodule
