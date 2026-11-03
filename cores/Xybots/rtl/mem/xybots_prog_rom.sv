`timescale 1ns/1ps
//============================================================================
//  Xybots 68000 program ROM — 192 KB (96K x 16) in on-chip block RAM.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_program_rom.sv`
//  (GPL-3.0-or-later); see NOTICE.md.  Resized for Xybots and split into two
//  byte lanes so Quartus infers a plain byte-enabled M10K RAM.
//
//  ---- what the four sockets are (SP-313 sheet 3) -------------------------
//    17C/D + 19C/D  PROM0  /CE = A17   -> 68000 0x000000-0x01FFFF  (2 x 64 KB)
//    17B   + 19B    PROM1  /CE = /A17  -> 68000 0x020000-0x03FFFF  (2 x 32 KB,
//                                         the upper half a fold of the lower)
//  ...which is exactly the flat 0x30000-byte `maincpu` image the MRA emits, so
//  this module is one linear 96K-word array and the socket decode disappears
//  apart from the PROM1 A16 fold: 17B/19B are 27256s, whose socket pin 1
//  carries 68000 A16 (`/A16B`) but is VPP on that part, so A16 is not decoded
//  there at all and 68000 0x030000-0x03FFFF reads the same bytes as
//  0x020000-0x02FFFF.
//  (A18-A22 are undecoded on the board, so the whole A23 = 0 half mirrors every
//  0x40000; that mirroring belongs to the bus decoder, not to the ROM.)
//
//  ---- read port -----------------------------------------------------------
//  `rd_a` is the 68000 WORD address A17..A1 (rd_a[0] = A1), i.e. byte address
//  >> 1 with A18+ already stripped by the bus decoder.  Registered read: data
//  is valid ONE clk after the address, and the address must be stable for that
//  clock (the bus adapter holds it for the whole 68000 cycle anyway).
//
//  SLAPSTIC (sheet 2, 14B + 13C LS157):
//    `slap_sel`  = /SLAPSTIC asserted, i.e. A23=0 & A17=0 & A16=0 & A15=1.
//                  Pure address decode — no /AS, no R/W qualifier.
//    `slap_bank` = {BS1, BS0} from the SLAPSTIC's pins 9/10.
//  The 13C LS157 substitutes SA14 = BS1 for A14 and SA13 = BS0 for A13, and
//  those two substituted pins reach ONLY the PROM0 pair, so the substitution is
//  suppressed here whenever A17 = 1 (PROM1 selected).  Result: an 8 KB page at
//  0x008000-0x009FFF repeated four times over 0x8000-0xFFFF, exactly MAME's
//  `configure_entries(0, 4, base + 0x8000, 0x2000)`.
//
//  ---- byte order (the one thing that must not be guessed) -----------------
//  Download byte 2N is the FIRST byte of the MRA's interleave (map="01") = the
//  68000 word's HIGH lane D15:8; byte 2N+1 (map="10") is D7:0.  Reversing this
//  byte-swaps every opcode; the CPU then fetches a garbage reset vector and
//  runs nonsense from its first instruction, with no error message anywhere.
//
//  ---- resource ------------------------------------------------------------
//  96K x 8 per lane = 96 M10K per lane (an M10K holds 1 KB of data at x8 or
//  x16 — the extra 2048 parity bits are unreachable at those widths), so
//  **192 M10K total**, out of the DE10-Nano's 553 blocks.
//  Two byte-wide arrays (rather than one 16-bit array with bit-select writes)
//  are used deliberately: it is the textbook byte-enable inference pattern and
//  removes any doubt about Quartus picking M10K over LABs.  No megafunction
//  instantiation, no init file — the loader fills it at download time.
//============================================================================

module xybots_prog_rom
(
	input  logic        clk,

	// loader write port (byte stream from xybots_rom_loader)
	input  logic        wr,
	input  logic [17:0] wr_addr,    // byte offset 0..0x2FFFF
	input  logic  [7:0] wr_data,

	// 68000 read port (16-bit big-endian word)
	input  logic [16:0] rd_a,       // 68000 A17..A1, BEFORE bank substitution
	input  logic        slap_sel,   // /SLAPSTIC asserted (active-high here)
	input  logic  [1:0] slap_bank,  // {BS1, BS0}
	output logic [15:0] rd_data
);

	localparam int WORDS = 98304;   // 0x30000 bytes / 2

	// ---- 13C LS157: SA14/SA13 replace A14/A13, PROM0 pins only -------------
	wire        prom1   = rd_a[16];                  // A17 = 1 -> 17B/19B pair
	wire [1:0]  bank_ab = (slap_sel && !prom1) ? slap_bank : rd_a[13:12];
	// 27256 at 17B/19B: pin 1 is VPP, A16 undecoded -> 0x30000 folds onto 0x20000
	wire        a16_eff = prom1 ? 1'b0 : rd_a[15];
	wire [16:0] rd_addr = {rd_a[16], a16_eff, rd_a[14], bank_ab, rd_a[11:0]};

	logic [7:0] mem_hi [0:WORDS-1];   // even download byte -> D15:8
	logic [7:0] mem_lo [0:WORDS-1];   // odd  download byte -> D7:0

	// Power-up to 0.  Quartus zeroes M10K contents on configuration; the loop is
	// sim-only (keeps iverilog/verilator free of X on an unwritten hole) and is
	// skipped during synthesis, where >5000 iterations exceed the unroll limit.
`ifndef ALTERA_RESERVED_QIS
	initial begin
		for (int i = 0; i < WORDS; i++) begin
			mem_hi[i] = '0;
			mem_lo[i] = '0;
		end
	end
`endif

	logic [7:0] q_hi, q_lo;

	always_ff @(posedge clk) begin
		if (wr && !wr_addr[0]) mem_hi[wr_addr[17:1]] <= wr_data;
		if (wr &&  wr_addr[0]) mem_lo[wr_addr[17:1]] <= wr_data;
		q_hi <= mem_hi[rd_addr];
		q_lo <= mem_lo[rd_addr];
	end

	assign rd_data = {q_hi, q_lo};

endmodule
