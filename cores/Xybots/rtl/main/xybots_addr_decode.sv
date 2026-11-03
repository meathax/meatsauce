`timescale 1ns/1ps
//============================================================================
//  Xybots 68000 address decode — SP-313 sheet 2, gate for gate.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Every select below is read off the drawn decoders on sheet 2, not off
//  MAME's `main_map`.  The mirrors MAME documents fall OUT of the address bits
//  those decoders never look at, so the two descriptions agree over the whole
//  24-bit space (see the mirror note at the end).
//
//  ---- the gates -----------------------------------------------------------
//    11A LS14  AS   = ~/AS                       (active-high copy)
//    11A LS14  /R   = ~R/W                       (low during READS)
//    9F  LS04  /W   = ~/R = R/W                  (low during WRITES)
//    11B LS32  /WH  = /UDS | /W ;  /WL = /LDS | /W
//    2A  LS08  BOARDSEL = A23 & AS
//    10C LS00  /ROM      = ~( ~A23 & AS )
//    9C  LS10  /SLAPSTIC = ~( ~A23 & A15 & ~(A17 | A16) )      <- NO /AS, NO R/W
//    1A  LS00  /VRAM     = ~( BOARDSEL & ~A14 )
//    1A  LS00  /IOEN     = ~( BOARDSEL &  A14 )   -> 11D LS139 half 1, pin 1
//    11D LS139 half 1 : {B,A} = {A13,A12}
//              1Y0 /CRAM   1Y1 /EEROM   1Y2 -> /IOSEL   1Y3 unused (0x807000)
//    11B LS32  /IOSEL = /AS | 1Y2
//    11D LS139 half 2 (READ decoder) : {B,A} = {A9,A8},
//              2G = A11 | /IOSEL   -> enabled only while A11 = 0.
//              **No R/W, /UDS or /LDS qualifier.**  A10 IS NOT DECODED, so
//              /AUDRD, /SW and /SYSIN each answer twice inside 0x806000-7FF.
//              2Y0 /AUDRD  2Y1 /SW  2Y2 /SYSIN  2Y3 unused (0x806300)
//    10B LS138 (WRITE decoder) : {C,B,A} = {A10,A9,A8},
//              G1 = A11, /G2A = /W, /G2B = /IOSEL  -> writes in 0x806800-FFF.
//              **No /UDS or /LDS qualifier**: a high-byte-only write strobes
//              them just as a word write does.
//              Y0 /UNLOCK  Y1 /AUDWR  Y2 /WDOG  Y3 /VIDACK
//              Y4 nc(0x806C00)  Y5 nc(0x806D00)  Y6 /AUDRES  Y7 nc(0x806F00)
//    10A LS20  /VPA = ~( FC0 & FC1 & FC2 & AS )   -> all IRQs autovectored
//
//  ---- the three bare stubs ------------------------------------------------
//  Y4/Y5/Y7 leave the LS138 on unlabelled stubs.  The program writes 0x20/0x24
//  to 0x806D00 at pc 0x54E and 0x55C, and 0x17 at 0x1C66; on this board those
//  are no-ops.  They are decoded anyway — as OUTPUTS that reach nothing — so
//  that nothing else can answer there, and because /DTACK depends on no strobe
//  at all the cycle still terminates normally.
//
//  ---- mirrors, i.e. which bits nobody looks at ----------------------------
//  A23 = 1 half:  A22..A15 are not decoded at all -> everything repeats every
//  0x8000, which is MAME's `.mirror(0x7f8000)`.  Inside the I/O block A7..A1
//  are ignored, giving the 0x100-byte pages.  /CRAM covers 0x804000-0x804FFF
//  but only A10..A1 reach the RAM -> MAME's 0x800 palette mirror.  /EEROM
//  covers 0x805000-0x805FFF but the X2804A only has A0..A8 -> MAME's 0xc00.
//  A23 = 0 half:  only A17 (ROM /CE) and A16/A15 (slapstic) are decoded, so
//  the ROM repeats every 0x40000, which is MAME's `.mirror(0x7c0000)`.
//============================================================================

module xybots_addr_decode
(
	// 68000 A23..A1.  There is no A0 anywhere on this board; the byte lane is
	// /UDS //LDS and nothing else.
	input  logic [23:1] a,

	input  logic        as,       // active-high copy of /AS (11A LS14 3->4)
	input  logic        uds_n,
	input  logic        lds_n,
	input  logic        rw,       // 1 = read, 0 = write (68000 R/W pin)
	input  logic  [2:0] fc,

	// ---- derived control ----
	output logic        r_n,      // /R  : low during reads
	output logic        w_n,      // /W  : low during writes
	output logic        wh_n,     // /WH : /UDS | /W
	output logic        wl_n,     // /WL : /LDS | /W
	output logic        boardsel,

	// ---- chip selects ----
	output logic        rom_n,
	output logic        slapstic_n,
	output logic        vram_n,
	output logic        ioen_n,
	output logic        cram_n,
	output logic        eerom_n,
	output logic        io7000_n, // 11D 1Y3, 0x807000, no net on the sheet
	output logic        iosel_n,

	// ---- read decoder, 11D LS139 half 2 ----
	output logic        audrd_n,
	output logic        sw_n,
	output logic        sysin_n,
	output logic        rd3_n,    // 2Y3, 0x806300, no net on the sheet

	// ---- write decoder, 10B LS138 ----
	output logic        unlock_n,
	output logic        audwr_n,
	output logic        wdog_n,
	output logic        vidack_n,
	output logic        nc4_n,    // Y4 0x806C00 — bare stub, reaches nothing
	output logic        nc5_n,    // Y5 0x806D00 — bare stub, reaches nothing
	output logic        audres_n,
	output logic        nc7_n,    // Y7 0x806F00 — bare stub, reaches nothing

	// ---- autovector ----
	output logic        vpa_n
);

	// ---- 11A LS14 / 9F LS04 / 11B LS32 ----------------------------------
	assign r_n  = ~rw;            // 11A LS14 13->12
	assign w_n  = rw;             // 9F  LS04 11->10  (= ~r_n)
	assign wh_n = uds_n | w_n;    // 11B LS32 13,12->11
	assign wl_n = lds_n | w_n;    // 11B LS32  2, 1-> 3

	// ---- 2A LS08 / 10C LS00 / 9C LS10 / 1A LS00 -------------------------
	assign boardsel   = a[23] & as;
	assign rom_n      = ~(~a[23] & as);
	// 1B LS02 (8=A17, 9=A16 -> 10) feeds 9C LS10 pin 13.
	assign slapstic_n = ~(~a[23] & a[15] & ~(a[17] | a[16]));
	assign vram_n     = ~(boardsel & ~a[14]);
	assign ioen_n     = ~(boardsel &  a[14]);

	// ---- 11D LS139 half 1 : 1A = A12, 1B = A13, 1G = /IOEN ---------------
	wire [1:0] sel1 = {a[13], a[12]};
	assign cram_n    = ~(~ioen_n & (sel1 == 2'd0));
	assign eerom_n   = ~(~ioen_n & (sel1 == 2'd1));
	wire   io6000_n  = ~(~ioen_n & (sel1 == 2'd2));
	assign io7000_n  = ~(~ioen_n & (sel1 == 2'd3));

	// ---- 11B LS32 (4 = /AS, 5 = 1Y2 -> 6) --------------------------------
	assign iosel_n = ~as | io6000_n;

	// ---- 11D LS139 half 2, the READ decoder ------------------------------
	// 2G = 11B LS32 (9 = A11, 10 = /IOSEL -> 8).  A10 is NOT an input, so the
	// three ports answer again at 0x806400/0x806500/0x806600.
	wire       rden = ~(a[11] | iosel_n);
	wire [1:0] sel2 = {a[9], a[8]};
	assign audrd_n = ~(rden & (sel2 == 2'd0));
	assign sw_n    = ~(rden & (sel2 == 2'd1));
	assign sysin_n = ~(rden & (sel2 == 2'd2));
	assign rd3_n   = ~(rden & (sel2 == 2'd3));

	// ---- 10B LS138, the WRITE decoder ------------------------------------
	wire       wren = a[11] & ~w_n & ~iosel_n;
	wire [2:0] sel3 = {a[10], a[9], a[8]};
	assign unlock_n = ~(wren & (sel3 == 3'd0));
	assign audwr_n  = ~(wren & (sel3 == 3'd1));
	assign wdog_n   = ~(wren & (sel3 == 3'd2));
	assign vidack_n = ~(wren & (sel3 == 3'd3));
	assign nc4_n    = ~(wren & (sel3 == 3'd4));
	assign nc5_n    = ~(wren & (sel3 == 3'd5));
	assign audres_n = ~(wren & (sel3 == 3'd6));
	assign nc7_n    = ~(wren & (sel3 == 3'd7));

	// ---- 10A LS20, /VPA --------------------------------------------------
	assign vpa_n = ~(fc[0] & fc[1] & fc[2] & as);

	// A22..A18 and A7..A1 reach no decoder on sheet 2 at all.  That omission is
	// the WHOLE source of MAME's `.mirror(0x7c0000)` on the ROM half and
	// `.mirror(0x7f8000)` plus the 0x100-byte I/O pages on the board half, so
	// it is deliberate; sink the bits so the tools agree.
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_a = &{1'b0, a[22:18], a[7:1]};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
