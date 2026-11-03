`timescale 1ns/1ps
//============================================================================
//  Atari SLAPSTIC 137412-107 — SP-313 sheet 2, location 14B ("SLAPSTK7").
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  The state machine below was written from SP-313 sheet 2 and checked against
//  MAME's `slapstic.cpp` (BSD-3-Clause); see NOTICE.md.
//
//  The slapstic is a 20-pin state machine that watches the CPU address bus and
//  drives two bank-select outputs.  On Xybots it replaces A13/A14 into the
//  PROM0 ROM pair, giving four 8 KB pages inside 68000 0x008000-0x00FFFF.
//
//  ---- pinout as wired on sheet 2 ----------------------------------------
//
//      /CS  (6)  = /SLAPSTIC   9C LS10(/A23, A15B, 1B LS02(A17, A16B))
//                              -> LOW for A23=0 & A17=0 & A16=0 & A15=1.
//                              NO /AS and NO R/W qualifier: reads AND writes,
//                              anywhere in 0x008000-0x00FFFF and its 0x40000
//                              mirrors, assert it.
//      CK   (7)  = /AS         one edge per 68000 bus cycle, whatever the
//                              address — /CS is a data input, not a gate.
//      A1..A14 (12,13,14,15,16,17,18,19,20,1,2,3,4,5) = buffered A1B..A14B,
//                              i.e. the chip's own A0..A13 = 68000 A1..A14.
//      BS1  (9), BS0 (10)      -> 13C LS157 (SEL = /SLAPSTIC): SA14 = BS1 or
//                              A14, SA13 = BS0 or A13.
//
//  ---- what this module models ------------------------------------------
//
//  The transition structure MAME's `slapstic.cpp` gives for chip class
//  103-110, which is what 137412-107 belongs to.  MAME qualifies each match
//  with a 32-bit range test as well as the chip's own address mask; on this
//  board that range test reduces to exactly "A23=0 and A17=0 and A16=0 and
//  A15=1", which IS /SLAPSTIC, so the two forms below are all that is needed:
//
//      test_in (mask, value)  ==  !cs_n && (a & mask) == value
//      test_any(mask, value)  ==            (a & mask) == value
//
//  `test_any` is used for alt1 only — the one access that may be made from
//  anywhere, in or out of the banked window.
//
//  Sheet 2 puts no R/W term on /CS or CK, so `we` does not reach the state
//  machine.  It is a port only because the caller must not be tempted to gate
//  `cyc` on reads: the ROM's bank-switch library at pc 0x1051C switches banks
//  with WRITE cycles into ROM space.
//
//  Only the 103-110 transition structure is implemented.  The table is a
//  parameter set so another chip of the same class drops in, but 101/102 and
//  111-118 need different active/alt_valid/alt_select variants (and, for
//  111-118, the ADDITIVE states).  137412-107 is NO_ADDITIVE, so its additive
//  states are unreachable and are deliberately absent rather than
//  present-but-untestable.
//============================================================================

module xybots_slapstic #(
	// slapstic_data for 137412-107, verbatim from slapstic.cpp.  All values are
	// CHIP word addresses (= 68000 A14..A1), which is what MAME's tables hold.
	parameter logic [1:0]  BANKSTART = 2'd3,
	parameter logic [13:0] BANK0     = 14'h0018,
	parameter logic [13:0] BANK1     = 14'h001A,
	parameter logic [13:0] BANK2     = 14'h001C,
	parameter logic [13:0] BANK3     = 14'h001E,
	parameter logic [13:0] ALT1_M    = 14'h007F,
	parameter logic [13:0] ALT1_V    = 14'h006B,
	parameter logic [13:0] ALT2_M    = 14'h3FFF,
	parameter logic [13:0] ALT2_V    = 14'h3D52,
	parameter logic [13:0] ALT3_M    = 14'h3FFC,
	parameter logic [13:0] ALT3_V    = 14'h3D64,
	parameter logic [13:0] ALT4_M    = 14'h3FF9,
	parameter logic [13:0] ALT4_V    = 14'h0018,
	parameter int          ALTSHIFT  = 0,
	parameter logic [13:0] BIT1_M    = 14'h3FF0,
	parameter logic [13:0] BIT1_V    = 14'h00A0,
	parameter logic [13:0] BIT2_M    = 14'h3FF9,
	parameter logic [13:0] BIT2_V    = 14'h0018,
	parameter logic [13:0] BIT3C0_M  = 14'h3FF3,
	parameter logic [13:0] BIT3C0_V  = 14'h00A0,
	parameter logic [13:0] BIT3S0_M  = 14'h3FF3,
	parameter logic [13:0] BIT3S0_V  = 14'h00A1,
	parameter logic [13:0] BIT3C1_M  = 14'h3FF3,
	parameter logic [13:0] BIT3C1_V  = 14'h00A2,
	parameter logic [13:0] BIT3S1_M  = 14'h3FF3,
	parameter logic [13:0] BIT3S1_V  = 14'h00A3,
	parameter logic [13:0] BIT4_M    = 14'h3FF8,
	parameter logic [13:0] BIT4_V    = 14'h00B0
) (
	input  logic        clk,        // clk_sys
	input  logic        rst,        // active high; parks the chip at BANKSTART

	// One pulse per 68000 bus cycle = one CK (/AS) edge at 14B pin 7.  It must
	// pulse for EVERY cycle the chip can see, reads and writes alike, not only
	// for cycles inside the banked window: alt1 is matched with MAME's
	// `test_any`, and an out-of-window cycle breaks an alt sequence in
	// progress.  Gate it on nothing but "the 68000 completed a bus cycle".
	input  logic        cyc,
	input  logic        cs_n,       // /SLAPSTIC (14B pin 6), active low
	input  logic [14:1] a,          // 68000 A14..A1 == chip A13..A0

	// R/W of the cycle.  Present so the caller keeps the write cycles; the
	// state machine ignores it, exactly as MAME and sheet 2 do.
	/* verilator lint_off UNUSEDSIGNAL */
	input  logic        we,
	/* verilator lint_on UNUSEDSIGNAL */

	output logic [1:0]  bank,       // {BS1, BS0} -> 13C LS157

	// MAME's S_* encoding; diagnostic output, no consumer in the core.
	output logic [2:0]  dbg_state
);

	// MAME slapstic.h `enum { S_IDLE, S_ACTIVE, S_ALT_VALID, S_ALT_SELECT,
	// S_ALT_COMMIT, S_BIT_LOAD, S_BIT_SET_ODD, S_BIT_SET_EVEN, ... }`.
	localparam logic [2:0] ST_IDLE       = 3'd0;
	localparam logic [2:0] ST_ACTIVE     = 3'd1;
	localparam logic [2:0] ST_ALT_VALID  = 3'd2;
	localparam logic [2:0] ST_ALT_SELECT = 3'd3;
	localparam logic [2:0] ST_ALT_COMMIT = 3'd4;
	localparam logic [2:0] ST_BIT_LOAD   = 3'd5;
	localparam logic [2:0] ST_BIT_ODD    = 3'd6;
	localparam logic [2:0] ST_BIT_EVEN   = 3'd7;

	logic [2:0] state;
	logic [1:0] loaded_bank;

	// The 14 bits the chip sees.  68000 A0 does not exist on the bus, and MAME
	// masks bit 0 out of every test, so nothing here depends on byte lane.
	logic [13:0] ca;
	assign ca = a;

	logic in_win;
	assign in_win = ~cs_n;

	// checker::test_in()  -- in the window AND the masked bits match
	function automatic logic m_in(input logic [13:0] mask, input logic [13:0] val);
		m_in = in_win && ((ca & mask) == val);
	endfunction

	// checker::test_any() -- masked bits match, window irrelevant
	function automatic logic m_any(input logic [13:0] mask, input logic [13:0] val);
		m_any = ((ca & mask) == val);
	endfunction

	// checker::test_reset() / test_bank() -- full 14-bit compare, in window
	function automatic logic m_exact(input logic [13:0] val);
		m_exact = in_win && (ca == val);
	endfunction

	logic hit_reset, hit_b0, hit_b1, hit_b2, hit_b3;
	logic hit_alt1, hit_alt2, hit_alt3, hit_alt4;
	logic hit_bit1, hit_bit2, hit_bit4;
	logic hit_c0, hit_s0, hit_c1, hit_s1;   // as seen in the ODD half

	always_comb begin
		hit_reset = m_exact(14'h0000);
		hit_b0    = m_exact(BANK0);
		hit_b1    = m_exact(BANK1);
		hit_b2    = m_exact(BANK2);
		hit_b3    = m_exact(BANK3);
		hit_alt1  = m_any(ALT1_M, ALT1_V);
		hit_alt2  = m_in (ALT2_M, ALT2_V);
		hit_alt3  = m_in (ALT3_M, ALT3_V);
		hit_alt4  = m_in (ALT4_M, ALT4_V);
		hit_bit1  = m_in (BIT1_M, BIT1_V);
		hit_bit2  = m_in (BIT2_M, BIT2_V);
		hit_bit4  = m_in (BIT4_M, BIT4_V);
		hit_c0    = m_in (BIT3C0_M, BIT3C0_V);
		hit_s0    = m_in (BIT3S0_M, BIT3S0_V);
		hit_c1    = m_in (BIT3C1_M, BIT3C1_V);
		hit_s1    = m_in (BIT3S1_M, BIT3S1_V);
	end

	// alt_select_101_110: m_loaded_bank = (addr >> (shift + altshift)) & 3,
	// where `shift` is 1 for a 16-bit space.  On the chip's own pins that is
	// simply ca[ALTSHIFT+1 : ALTSHIFT].
	logic [1:0] alt_pick;
	assign alt_pick = ca[ALTSHIFT+1 -: 2];

	always_ff @(posedge clk) begin
		if (rst) begin
			state       <= ST_IDLE;
			bank        <= BANKSTART;
			loaded_bank <= 2'd0;
		end else if (cyc) begin
			case (state)

			// struct idle
			ST_IDLE:
				if (hit_reset) state <= ST_ACTIVE;

			// struct active_103_110
			ST_ACTIVE:
				if (hit_b0)        begin bank <= 2'd0; state <= ST_IDLE; end
				else if (hit_b1)   begin bank <= 2'd1; state <= ST_IDLE; end
				else if (hit_b2)   begin bank <= 2'd2; state <= ST_IDLE; end
				else if (hit_b3)   begin bank <= 2'd3; state <= ST_IDLE; end
				else if (hit_alt1) state <= ST_ALT_VALID;
				else if (hit_bit1) state <= ST_BIT_LOAD;

			// struct alt_valid_103_110 -- anything else breaks the sequence
			ST_ALT_VALID:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_alt2) state <= ST_ALT_SELECT;
				else               state <= ST_ACTIVE;

			// struct alt_select_101_110 -- anything else breaks the sequence
			ST_ALT_SELECT:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_alt3) begin
					loaded_bank <= alt_pick;
					state       <= ST_ALT_COMMIT;
				end else           state <= ST_ACTIVE;

			// struct alt_commit -- unrelated accesses are ignored, not fatal
			ST_ALT_COMMIT:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_alt4) begin
					bank  <= loaded_bank;
					state <= ST_IDLE;
				end

			// struct bit_load
			ST_BIT_LOAD:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_bit2) begin
					loaded_bank <= bank;
					state       <= ST_BIT_ODD;
				end

			// struct bit_set(odd)
			ST_BIT_ODD:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_c0)   begin loaded_bank[0] <= 1'b0; state <= ST_BIT_EVEN; end
				else if (hit_s0)   begin loaded_bank[0] <= 1'b1; state <= ST_BIT_EVEN; end
				else if (hit_c1)   begin loaded_bank[1] <= 1'b0; state <= ST_BIT_EVEN; end
				else if (hit_s1)   begin loaded_bank[1] <= 1'b1; state <= ST_BIT_EVEN; end
				else if (hit_bit4) begin bank <= loaded_bank;    state <= ST_IDLE;     end

			// struct bit_set(even) -- the four twiddle tests swap roles
			ST_BIT_EVEN:
				if (hit_reset)     state <= ST_ACTIVE;
				else if (hit_s1)   begin loaded_bank[0] <= 1'b0; state <= ST_BIT_ODD; end
				else if (hit_c1)   begin loaded_bank[0] <= 1'b1; state <= ST_BIT_ODD; end
				else if (hit_s0)   begin loaded_bank[1] <= 1'b0; state <= ST_BIT_ODD; end
				else if (hit_c0)   begin loaded_bank[1] <= 1'b1; state <= ST_BIT_ODD; end
				else if (hit_bit4) begin bank <= loaded_bank;    state <= ST_IDLE;    end

			default: state <= ST_IDLE;
			endcase
		end
	end

	assign dbg_state = state;

endmodule
