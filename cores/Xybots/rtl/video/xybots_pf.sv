`timescale 1ns/1ps
//============================================================================
//  Xybots playfield layer — SP-313 sheet 7 (13F/13E LS273D, 13J LS174D,
//  PFROM0-3, 6M/5M LS157A, 6L/5L LS194A, 13K LS273).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  ---- the sequence, in SYNGEN counts -------------------------------------
//  For playfield tile column k = h[8:3]:
//
//    h = 8k+4   PLAYFIELD VRAC phase: the word is on the SCRAM data bus
//    -> 8k+5    13F/13E LS273D clock on 4HD1H rising: PFHFLIP (bit 15),
//               colour (bits 14:11) and the 13-bit code (bits 12:0) latched.
//               HERE the core departs from the board: instead of driving an
//               asynchronous EPROM it issues ONE xybots_mem PF-client request
//               for the whole 4-byte tile row, and the row is displayed one
//               tile later.  See PIPE_DLY below.
//    -> 8k+13   the prefetched row moves into the display slot
//    h = 8k+14  ROM byte index {~4HD1H, 2HD1H} ^ {flip,flip} = 0
//    -> 8k+15   6L/5L LS194A parallel load (S1 = /1H), 13J-style colour move
//               ... and so on every two counts for bytes 1, 2, 3
//
//  so `pfpix` presents pixel p of column k during count 8k+15+p and `pfcol`
//  over the same eight counts.  Two more pipeline stages downstream put it on
//  the DAC during count 8k+17+p = hpos 8k+p once the whole raster is shifted
//  by PIPE_DLY.
//
//  ---- PIPE_DLY: why the playfield runs one tile behind the drawing --------
//  The board's tile ROMs are asynchronous: the word is latched entering count
//  8k+5 and the first byte is wanted by the LS194 load at 8k+7 -- two pixel
//  clocks, 16 clk_sys.  Here the tiles are in SDRAM, which guarantees a row
//  only inside 64 clk_sys (11 idle, 31 worst measured).  So the fetch is issued
//  at 8k+5 and the row is not needed until the load at 8k+15 -- 10 pixel
//  clocks, 80 clk_sys.  The deadline enforced here is the swap edge at 8k+13,
//  i.e. 8 pixel clocks = 64 clk_sys, and `late` pulses if it is ever missed.
//
//  Nothing about the VRAM side moves: the tile word is still read at the drawn
//  phase from the drawn address.  xybots_video delays the alphanumerics, the
//  motion-object nibbles AND the blanking/sync by the same PIPE_DLY, so the
//  picture that leaves the core is identical to the board's.
//
//  ---- ROM address, straight off sheet 7 ----------------------------------
//    A15..A5 = PFPIC10..PFPIC0        A4..A2 = 4V, 2V, 1V
//    A1 = /4HD1H XOR PFHFLIP          A0 =  2HD1H XOR PFHFLIP
//    socket = {PFPIC12, PFPIC11} -> MAME "tiles" region offset * 0x10000
//  so the byte address is code[12:0]*32 + row*4 + index and the request
//  address (bits 17:2 of it) is simply {code[12:0], row[2:0]}.
//
//  The empty 9L socket ({PFPIC12,PFPIC11} = 2, region 0x20000-0x2FFFF) floats
//  and reads as 0xFF on the board; the MRA materialises 0xFF there while MAME
//  leaves 0x00.  No code in the shipping game ever addresses that region — it
//  was counted as zero over every captured frame — so the difference is real
//  but not observable.
//============================================================================

module xybots_pf (
	input  logic        clk,
	input  logic        ce_7m,
	input  logic        reset,

	// ---- SYNGEN counters ----
	input  logic  [8:0] h,
	input  logic  [7:0] v,

	// ---- video-side SCRAM data bus ----
	input  logic [15:0] scram_d,

	// ---- xybots_mem playfield tile client ----
	output logic        pf_req,
	output logic [17:2] pf_addr,
	input  logic        pf_valid,
	input  logic [31:0] pf_data,

	// ---- pixel stream: valid during count h for hpos = h - 7 - PIPE_DLY ----
	output logic  [3:0] pfpix,
	output logic  [3:0] pfcol,

	// ---- diagnostic: a row fetch missed the 64 clk_sys deadline ----
	output logic        late
);

	// The last column this module fetches.  336 visible pixels means the last
	// column a viewer can see is 41; LAST_COL = 42 keeps one column of margin
	// past it.  The board goes on fetching columns 43..56 during HBLANK and
	// never displays them; skipping those here keeps the SDRAM load at the
	// 43 tile rows per line the graphics arbiter is sized for.
	localparam logic [5:0] LAST_COL = 6'd42;

	// =====================================================================
	//  13F / 13E LS273D — clocked by 4HD1H, which rises entering count h ≡ 5,
	//  so the PRE-edge condition is h[2:0] == 4.  The same edge starts the row
	//  fetch and rotates the prefetch pipeline.
	// =====================================================================
	wire tile_edge = ce_7m & (h[2:0] == 3'd4);
	wire col_used  = (h[8:3] <= LAST_COL);

	logic [31:0] row_next, row_cur;
	logic  [4:0] attr_next, attr_cur;    // {PFHFLIP, colour[3:0]}
	logic        got;                    // row_next holds a completed fetch

	always_ff @(posedge clk) begin
		if (reset) begin
			pf_req    <= 1'b0;
			pf_addr   <= '0;
			row_next  <= '0;
			row_cur   <= '0;
			attr_next <= '0;
			attr_cur  <= '0;
			got       <= 1'b1;      // nothing outstanding out of reset
			late      <= 1'b0;
		end else begin
			late <= 1'b0;

			// the SDRAM client: one request per tile, held until its valid
			if (pf_req && pf_valid) begin
				row_next <= pf_data;
				pf_req   <= 1'b0;
				got      <= 1'b1;
			end

			if (tile_edge) begin
				// the prefetch becomes the tile being displayed
				row_cur  <= row_next;
				attr_cur <= attr_next;
				if (!got && col_used) late <= 1'b1;
				got <= 1'b0;

				// 13F/13E latch the new word and the fetch starts immediately
				attr_next <= {scram_d[15], scram_d[14:11]};
				pf_addr   <= {scram_d[12:0], v[2:0]};
				pf_req    <= col_used;
				if (!col_used) begin
					row_next <= '0;
					got      <= 1'b1;
				end
			end
		end
	end

	// =====================================================================
	//  ROM byte index and the 6M/5M LS157A nibble swap
	//    A1 = /4HD1H XOR PFHFLIP,  A0 = 2HD1H XOR PFHFLIP
	//  4HD1H(h) = 4H(h-1) is high for h ≡ 5,6,7,0;  2HD1H(h) = 2H(h-1) is high
	//  for h ≡ 3,4,7,0.  Over the eight counts a tile is displayed the index
	//  therefore runs 0,0,1,1,2,2,3,3 unflipped and 3,3,2,2,1,1,0,0 flipped.
	// =====================================================================
	wire h_4hd1h = (h[2:0] == 3'd5) | (h[2:0] == 3'd6) | (h[2:0] == 3'd7) | (h[2:0] == 3'd0);
	wire h_2hd1h = (h[2:0] == 3'd3) | (h[2:0] == 3'd4) | (h[2:0] == 3'd7) | (h[2:0] == 3'd0);
	wire flip    = attr_cur[4];
	wire [1:0] byte_idx = {~h_4hd1h, h_2hd1h} ^ {2{flip}};

	wire [7:0] rb0 = row_cur[7:0];
	wire [7:0] rb1 = row_cur[15:8];
	wire [7:0] rb2 = row_cur[23:16];
	wire [7:0] rb3 = row_cur[31:24];

	logic [7:0] rom_byte;
	always_comb begin
		case (byte_idx)
			2'd0:    rom_byte = rb0;
			2'd1:    rom_byte = rb1;
			2'd2:    rom_byte = rb2;
			default: rom_byte = rb3;
		endcase
	end

	// MAME's gfx_8x8x4_packed_msb: the HIGH nibble is the left pixel of the
	// pair.  6M/5M swap the two nibbles when PFHFLIP is set.
	wire [3:0] pix_first  = flip ? rom_byte[3:0] : rom_byte[7:4];
	wire [3:0] pix_second = flip ? rom_byte[7:4] : rom_byte[3:0];

	// =====================================================================
	//  6L / 5L LS194A — S1 = /1H, CK = VIDCLK: parallel load on the edge whose
	//  PRE-edge count is even, one shift per count.  Two pixels per load.
	//  13K LS273 (CK = /7M) is the half-count register that follows; it is
	//  folded into the compositor's first ce_7m stage in xybots_video.
	// =====================================================================
	logic [3:0] sr_now, sr_nxt;
	always_ff @(posedge clk) begin
		if (reset) begin
			sr_now <= '0;
			sr_nxt <= '0;
		end else if (ce_7m) begin
			if (!h[0]) begin
				sr_now <= pix_first;
				sr_nxt <= pix_second;
			end else begin
				sr_now <= sr_nxt;
			end
		end
	end

	// =====================================================================
	//  13J LS174D — CK = 2HD1H, which rises entering counts h ≡ 3 and h ≡ 7,
	//  i.e. on the edges whose PRE-edge count has h[1:0] == 2.  That is exactly
	//  the extra tap that lines the colour up with its own tile's pixels.
	// =====================================================================
	logic [3:0] col_r;
	always_ff @(posedge clk) begin
		if (reset)                            col_r <= '0;
		else if (ce_7m && (h[1:0] == 2'b10))  col_r <= attr_cur[3:0];
	end

	assign pfpix = sr_now;
	assign pfcol = col_r;

	// v[7:3] is the tile row for the SCRAM address, formed in xybots_video.
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_pf = |v[7:3];
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
