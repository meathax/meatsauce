`timescale 1ns/1ps
//============================================================================
//  Xybots SDRAM loader-writer — packs the download byte stream into 16-bit
//  words and writes the two graphics regions through the SINGLE gfx_mem write
//  port.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_sdram_loader.sv`
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  ---- why the mapping is a straight copy ----------------------------------
//  Both Xybots graphics regions are already laid out as 32 bytes per 8x8 4bpp
//  tile with the row bits directly below the code bits:
//
//    playfield : byte = code[12:0]*32 + row(4V,2V,1V)*4 + (A1,A0), where
//                {PFPIC12,PFPIC11} pick the socket = byte address 17:16 and
//                PFPIC10..0 address inside it.
//    sprites   : byte = code[13:0]*32 + row(MOA4,MOA3)*4 + (A1,A0), where
//                {MOPIC13,MOPIC12,MOPIC11} pick the socket.
//
//  So one 8-pixel row of either layer is 4 CONSECUTIVE bytes = 2 consecutive,
//  naturally 2-aligned 16-bit words, and a straight linear byte->word mapping
//  already puts them where the read clients want them.  No reorganiser, no
//  permutation, nothing to get wrong.  (A1/A0 are XOR'd with the h-flip bit on
//  the board; that happens in the video pixel path, not here — the fetch always
//  reads the whole 4-byte row.)
//
//  ---- SDRAM word map (word addresses; 32 MB module, 768 KB used) ----------
//    TILE_BASE 0x000000 .. 0x01FFFF   tiles   0x40000 bytes
//    SPR_BASE  0x020000 .. 0x05FFFF   sprites 0x80000 bytes
//
//    tiles   : word = TILE_BASE + tiles_addr[17:1]
//    sprites : word = SPR_BASE  + sprites_addr[18:1]
//
//  ---- byte lanes ----------------------------------------------------------
//  EVEN download byte -> D7:0, ODD download byte -> D15:8.  A tile row is then
//  {word1, word0} = {b3, b2, b1, b0} with b0 the (A1,A0)=00 ROM byte — the
//  leftmost pixel pair before h-flip.  (This is the opposite convention from
//  the program ROM, which is big-endian because the MRA interleaves it into
//  68000 words; the graphics ROMs are byte-addressed devices with no word
//  order of their own, so the natural little-endian packing is used and both
//  sides of the datapath agree on it.)
//
//  Even and odd bytes of a word are always consecutive in the download stream,
//  so the even byte is latched and the word is emitted on the odd byte.
//  `wr_busy` is combinational and is asserted while a word is outstanding (and
//  in the cycle a word completes); drive `ioctl_wait` with it so the byte
//  stream can never outrun the SDRAM.
//
//  ---- the write-path rule -------------------------------------------------
//  This is a SINGLE write path through the shared `xybots_gfx_mem` controller
//  port — NOT a separate write client behind the read arbiter.  A write client
//  placed behind the arbiter gets pruned by Quartus; after any arbiter change,
//  check the fitter's map report for "Lost fanout" on the request/we nets.
//
//  ---- two details worth knowing -------------------------------------------
//  `lo_buf` latches an even byte in ANY state, not only in L_IDLE.  Dropping an
//  even byte that arrives while a word is outstanding would pair the NEXT odd
//  byte with a stale low byte — a silently corrupted word rather than a lost
//  one.  `wr_busy` makes that unreachable so long as it is wired to
//  `ioctl_wait`, and the belt-and-braces latch costs nothing.
//
//  An odd (word-completing) byte arriving while the previous word is still
//  outstanding IS unrecoverable, so a simulation-only check at the bottom of
//  this file reports it rather than letting it vanish.
//============================================================================

module xybots_sdram_loader #(
	parameter int AW = 24,
	parameter logic [AW-1:0] TILE_BASE = 24'h000000,
	parameter logic [AW-1:0] SPR_BASE  = 24'h020000
)(
	input  logic          clk,
	input  logic          reset,

	// ---- byte strobes from xybots_rom_loader (the SDRAM regions only) ----
	input  logic          tiles_wr,
	input  logic [17:0]   tiles_addr,
	input  logic          sprites_wr,
	input  logic [18:0]   sprites_addr,
	input  logic  [7:0]   ld_data,
	output logic          wr_busy,      // -> ioctl_wait (back-pressure)

	// ---- gfx_mem write port ----
	output logic          dl_wr,
	output logic [AW-1:0] dl_waddr,
	output logic [15:0]   dl_wdata,
	input  logic          dl_ack
);

	// ---- is this byte the even (first) or the word-completing (odd) one? ----
	wire tile_ev = tiles_wr   && !tiles_addr[0];
	wire tile_od = tiles_wr   &&  tiles_addr[0];
	wire spr_ev  = sprites_wr && !sprites_addr[0];
	wire spr_od  = sprites_wr &&  sprites_addr[0];

	wire any_ev = tile_ev | spr_ev;
	wire any_od = tile_od | spr_od;     // word-completing

	logic [7:0] lo_buf;                 // the latched even byte -> D7:0

	wire [AW-1:0] word_addr = tile_od
		? (TILE_BASE + {{(AW-17){1'b0}}, tiles_addr[17:1]})
		: (SPR_BASE  + {{(AW-18){1'b0}}, sprites_addr[18:1]});
	wire [15:0]   word_data = {ld_data, lo_buf};   // odd -> high, even -> low

	typedef enum logic [0:0] { L_IDLE, L_WR } lstate_t;
	lstate_t st;

	// combinational back-pressure: busy while writing, or the cycle a word completes
	assign wr_busy = (st == L_WR) || (st == L_IDLE && any_od);

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= L_IDLE; dl_wr <= 1'b0;
		end else begin
			// the even byte is latched whatever the state (see the header)
			if (any_ev) lo_buf <= ld_data;
			case (st)
				L_IDLE: begin
					dl_wr <= 1'b0;
					if (any_od) begin
						dl_waddr <= word_addr;
						dl_wdata <= word_data;
						dl_wr    <= 1'b1;
						st       <= L_WR;
					end
				end
				L_WR: begin
					if (dl_ack) begin dl_wr <= 1'b0; st <= L_IDLE; end
				end
				default: st <= L_IDLE;
			endcase
		end
	end

	// Simulation-only overrun check, in its own process so no synthesisable
	// always_ff contains a system task.  A word-completing (odd) byte arriving
	// while the previous word is still outstanding cannot be recovered — it
	// means `ioctl_wait` is not wired to `wr_busy`.
`ifndef ALTERA_RESERVED_QIS
	always @(posedge clk)
		if (!reset && st == L_WR && any_od)
			$display("ERROR: xybots_sdram_loader overrun - a word-completing byte arrived while a write was outstanding; ioctl_wait is not wired to wr_busy");
`endif

endmodule
