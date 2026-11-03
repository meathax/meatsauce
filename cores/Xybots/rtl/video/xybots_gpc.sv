`timescale 1ns/1ps
//============================================================================
//  Xybots GPC 14K — the Atari custom on SP-313 sheet 8 that turns the alpha
//  attribute nibble, the P bus, the M bus and PF/MO into the 10-bit colour-RAM
//  address.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- this is the one place MAME is the oracle ---------------------------
//  The GPC is an Atari custom and a black box: sheet 8 gives every pin
//  connection and nothing about the inside.  What the drawing DOES give is
//  the wiring order of the alpha attribute nibble:
//
//      D3 = SCRAMD15   D2 = SCRAMD12   D1 = SCRAMD13   D0 = SCRAMD14
//
//  and MAME's alpha tile info is `color = (data >> 12) & 7`,
//  `opaque = data & 0x8000`, with the "chars" gfx entry at palette base 0 and
//  4 pens per colour.  The only mapping consistent with both is
//
//      D3 = opaque,  D2 = colour bit 0,  D1 = colour bit 1,  D0 = colour bit 2
//
//  and that is a DEDUCTION FROM MAME, not from the schematic.  Likewise the
//  palette bases 0 / 256 / 512 (and the otherwise unused 768) come from MAME's
//  GFXDECODE entries.  Everything else below falls out of the sheet-8 gates.
//
//  ---- the address map ----------------------------------------------------
//    alpha wins (ANPIX != 0 or opaque)   CRAMA = {5'b0, acol[2:0], ANPIX[1:0]}
//    else PF/MO                          CRAMA = {2'b10, PFCOL, PFPIX}
//    else PRIEN & MOCOL3                 CRAMA = {2'b11, ~MOCOL, MOPIX}
//    else                                CRAMA = {2'b01,  MOCOL, MOPIX}
//  with MOCOL = ~LBCOL and MOPIX = ~LBPIX (the line buffers' inverted sense).
//
//  The third row is MAME's `pf[x] = (mo[x] ^ 0x2f0)`, the case its comment
//  calls "doesn't make sense from the schematics".  It does: 0x2f0 flips bit 9
//  and the colour nibble, so `0x100 | c<<4 | p` becomes `0x300 | ~c<<4 | p`,
//  and `~c` is exactly what the 11K mux puts on P[3:0] in that case -- SEL is
//  low only when PF/MO = 0, PRIEN = 1 and LBCOL3 = 0, i.e. MOCOL3 = 1.  So the
//  GPC simply takes its colour nibble from P[3:0] there and from ~M[7:4]
//  otherwise, and CRAMA[9] is MOCOL3 & PRIEN.
//
//  Sanity: ~c has bit 3 clear exactly when c has it set, so the motion object
//  occupies 0x100-0x17F and 0x300-0x37F and can never collide with the
//  playfield's 0x200-0x2FF.
//============================================================================

module xybots_gpc (
	// alphanumerics (GPC pins 20, 19 and 22..25)
	input  logic [1:0] anpix,
	input  logic [2:0] acol,
	input  logic       aopaque,

	// sheet-8 priority network
	input  logic       prien,
	input  logic       pf_mo,       // GPC pin 18
	input  logic [7:0] p_bus,       // pins 35..28
	input  logic [7:0] m_bus,       // pins 3, 1, 40..36, 2

	output logic [9:0] cram_a       // CA9..CA0
);

	// The alpha layer is on top; pen 0 is transparent unless the tile's opaque
	// bit (word bit 15) is set -- MAME's TILE_FORCE_LAYER0.
	wire alpha_on = (anpix != 2'b00) | aopaque;

	// M is the line buffer's byte, inverted sense; ~M is MAME's {colour, pen}.
	wire [3:0] mocol  = ~m_bus[7:4];
	wire [3:0] mopix  = ~m_bus[3:0];
	wire       mocol3 =  mocol[3];
	wire [3:0] p_lo   =  p_bus[3:0];   // = LBCOL exactly when the branch below fires

	always_comb begin
		if (alpha_on)                cram_a = {5'b00000, acol, anpix};
		else if (pf_mo)              cram_a = {2'b10, p_bus};
		else if (prien & mocol3)     cram_a = {2'b11, p_lo,  mopix};
		else                         cram_a = {2'b01, mocol, mopix};
	end

endmodule
