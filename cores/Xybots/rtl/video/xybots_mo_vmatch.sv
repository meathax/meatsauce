`timescale 1ns/1ps
//============================================================================
//  Xybots — SP-313 sheet 5: the motion-object vertical match (9D, 10D, 3D,
//  8D) and the picture-code adder (4D, 5D).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Purely combinational: this is the adder chain as drawn, with no registers.
//  `xybots_mo_fetch` supplies the latched object words and clocks the result
//  into the 1D LS174C / 5F-5E LS273F pipeline the sheet draws around it.
//
//  ---------------------------------------------------------------------------
//  WHAT THE CHAIN COMPUTES, AND HOW THAT WAS RESOLVED
//  ---------------------------------------------------------------------------
//  The LS283 symbols on sheet 5 carry high-side pin numbers that do not match
//  a real 74LS283, so their A/B/C0/S/C4 ROLE labels are authoritative and the
//  pin numbers are not.  Re-deriving the chain from what it has to produce:
//
//    9D  low nibble : A = MOV4..MOV1, B = 16V..2V, C0 = 8C LS32 (MOV0 | 1V)
//    10D high nibble: A = MOV8..MOV5, B = VBLANK,128V,64V,32V, C0 = 9D C4
//
//  `MOV0 | 1V` is exactly carry(MOV0 + 1V + 1), so 9D+10D compute the 9-bit
//        U = MOV[8:0] + V[8:0] + 1
//  where V[8] is VBLANK (there is no 256V net anywhere in SP-313).  The bit-0
//  sum, MOA2, is the matching XNOR — and sheet 5 builds MOA2 out of 2A LS08 +
//  1A LS00 + 4A LS04 + 1B LS02, which is an XNOR.  Two independent readings of
//  the same +1.
//
//  The +1 is the line-buffer pipeline: a column computed while the beam is on
//  line V is written into the off-screen buffer and read out on line V+1
//  (sheet 8, RSEL = 1V).  So U = MOV + D for the DISPLAYED line D, which is
//  MAME's coordinate directly.
//
//  MAME (`atarimo.cpp::render_object`) puts the object at
//        ypos = (-(Y + 8*height)) & 0x1FF
//  and draws 8*height lines from there, i.e. D is covered iff
//        (Y + D) mod 512 >= 512 - 8*height
//  and the row inside the object is (Y + D) mod 512 - (512 - 8*height).
//  Writing U = (Y + D) mod 512, h = height, hraw = h - 1 = MOVSIZ:
//        covered  <=>  U[8:6] == 3'b111  AND  U[5:3] + hraw >= 7
//        row      =    U[5:0] + 8h - 64
//        tile row =    row[5:3] = (U[5:3] + h) mod 8
//        pixel row=    row[2:0] = U[2:0]
//
//  That is precisely what 3D produces if its B operand is {1, U5, U4, U3}:
//        3D = (8 + hraw) + (8 + U[5:3]) + 1 = 17 + hraw + U[5:3]
//        S4       = 1  <=>  hraw + U[5:3] >= 7      -> the 4th 8D LS20 input
//        S3,S2,S1 = (1 + hraw + U[5:3]) mod 8 = the tile row
//  U[5] is 10D's S1, the one 10D output that otherwise goes nowhere.  Two
//  connections are ambiguous on the drawing and are read here as
//        3D B3  = 10D.S1
//        4D B1  = 3D.S1
//  4D's B1 is the load-bearing one: tied to GND the picture code would advance
//  two tiles per row and only four rows could be addressed, whereas 3D.S1
//  advances it one tile per row over eight — MAME's `code++` per row, and the
//  8-tile maximum the height field can express.
//
//  8D LS20 (4-input NAND) = /MOVMATCH = ~(10D.S2 & 10D.S3 & 10D.S4 & 3D.S4).
//
//  ---------------------------------------------------------------------------
//  THE PICTURE-CODE ADDER (4D, 5D)
//  ---------------------------------------------------------------------------
//  4D: A = MOPIC3..0, B = {GND, 3D.S3, 3D.S2, 3D.S1}, C0 = GND, S -> MOA8..5,
//      C4 -> 5D C0.
//  5D: A = MOPIC7..4, B = GND, S -> MOA12..9.  5D's C4 goes NOWHERE, and
//      MOPIC13..8 reach the ROM sockets unmodified through 5F/5E LS273F.  So
//      the add is EIGHT bits wide and a carry out of MOPIC7 is lost:
//        tile index = {MOPIC[13:8], (MOPIC[7:0] + tile_row)[7:0]}
//      MAME adds `code + row` in full 14-bit precision.  That is a real
//      difference between this core and MAME, kept because it is what the
//      board does.
//============================================================================

module xybots_mo_vmatch (
	// object word 2, as latched by 10F/9E LS174A
	input  logic [8:0]  mov,        // MOV8..MOV0   = word 2 bits 15:7
	input  logic [2:0]  movsiz,     // MOVSIZ2..0   = word 2 bits 2:0 = height-1
	// object word 0, as latched by 6F/6E LS273B
	input  logic [13:0] mopic,      // MOPIC13..0   = word 0 bits 13:0
	// the vertical counter operand, {VBLANK, 128V..1V}
	input  logic [8:0]  vop,

	output logic        movmatch,   // 8D LS20, active HIGH (the net is /MOVMATCH)
	output logic [2:0]  tile_row,   // 3D S3,S2,S1 -> 4D B3,B2,B1
	output logic [2:0]  moa,        // MOA4,MOA3,MOA2 = the row inside the tile
	output logic [13:0] rom_tile    // {MOPIC13:8, MOA12:5} = the 32-byte tile index
);

	// ---- 9D LS283 (low nibble) -------------------------------------------
	// C0 = 8C LS32 (1 = MOV0, 2 = 1V -> 3) = carry(MOV0 + 1V + 1).
	wire        c0_9d = mov[0] | vop[0];
	wire [4:0]  s9    = {1'b0, mov[4:1]} + {1'b0, vop[4:1]} + {4'b0, c0_9d};

	// MOA2 = 1B LS02 fed by 2A LS08 and 1A LS00 -> 4A LS04 = XNOR(MOV0, 1V),
	// which is bit 0 of MOV + V + 1.
	wire        moa2  = ~(mov[0] ^ vop[0]);

	// ---- 10D LS283 (high nibble), C0 = 9D C4 ------------------------------
	// C4 goes nowhere on 10D, so the sum is taken four bits wide.
	wire [3:0]  s10   = mov[8:5] + vop[8:5] + {3'b0, s9[4]};

	// U = MOV + V + 1, nine bits.
	wire [8:0]  u     = {s10, s9[3:0], moa2};

	// ---- 3D LS283: A = {1, MOVSIZ}, B = {1, U[5:3]}, C0 = 1 ---------------
	// 3D's C4 goes nowhere either; S4..S1 are the four bits that are used.
	wire [3:0]  s3d   = {1'b1, movsiz} + {1'b1, u[5:3]} + 4'd1;

	// ---- 8D LS20 ----------------------------------------------------------
	assign movmatch = u[8] & u[7] & u[6] & s3d[3];
	assign tile_row = s3d[2:0];
	assign moa      = u[2:0];

	// ---- 4D + 5D LS283: eight bits wide, the carry out of MOA12 is lost ----
	wire [7:0] moa_hi = mopic[7:0] + {5'b0, tile_row};
	assign rom_tile   = {mopic[13:8], moa_hi};

endmodule
