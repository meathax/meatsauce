// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - video timing and pixel output
//
//  Leland hardware timing (MAME leland_v.cpp):
//    pixel clock 7.159090 MHz (14.318181 MHz / 2)
//    424 x 256 total, 320 x 240 active -> 16.88 kHz / 65.95 Hz
//
//  Two layers are combined into a 10-bit pen that indexes the 1 KB colour RAM:
//    background (pen bits 5:0) - 8x8 tilemap from the bg PROM + 3 gfx planes
//    foreground (pen bits 9:6) - 4-bit bitmap in video RAM (two pixels/byte)
//  Colour RAM entries are BGR 2-3-3: [7:6] blue, [5:3] green, [2:0] red.
//============================================================================

import leland_board_pkg::*;

module leland_video
(
	input         clk_sys,
	input         reset,
	input         reset_cnt,  // raster counters: they keep running across game resets
	input         ce_pix,     // pixel clock enable (~7.16 MHz from 48 MHz)

	output reg    HBlank,
	output reg    HSync,
	output reg    VBlank,
	output reg    VSync,

	// Foreground bitmap read port (video RAM)
	output [16:0] vram_addr,
	input   [7:0] vram_data,

	// Palette read port (colour RAM)
	output  [9:0] cram_addr,
	input   [7:0] cram_data,

	// Ataxx board: RAM tilemap (tile RAM) and xRGB-444 palette RAM read ports. With
	// ataxx_mode low the colour RAM / PROM path above is used and these are idle.
	input         ataxx_mode,
	input         gfx_wide,   // 15-bit tile codes (256 KB planes); otherwise 14 bits
	output [15:0] qram_addr,
	input   [7:0] qram_data,
	output [10:0] pal_addr,
	input   [7:0] pal_data,

	// 24-bit RGB output, registered on ce_pix
	output reg [23:0] rgb,

	// Background scroll registers (master I/O 0x8C-0x8F / 0xCC-0xCF)
	input  [15:0] scroll_x,
	input  [15:0] scroll_y,

	// Graphics bank (MAME m_gfxbank), written by the master through the
	// AY-3-8910 port A: [5:4] character bank, [3] PROM bank
	input   [7:0] gfxbank,

	// Tile ROM reads share one SDRAM channel (rd2) with the board arbiter:
	// request/ack handshake, variable latency. One tile-row fetch is a PROM
	// byte followed by a 2-word burst holding the three gfx planes.
	output        sdram_rd2_req,
	input         sdram_rd2_ack,
	output [24:0] sdram_rd2_addr,
	input   [7:0] sdram_rd2_data,
	input  [15:0] sdram_rd2_data16,    // burst word 0: {plane1, plane0}
	input  [15:0] sdram_rd2_data16_hi, // burst word 1: {8'h00, plane2}
	input  [15:0] sdram_rd2_data16_w2, // burst word 2 (Ataxx: {plane5, plane4})

	// High for a whole tile fetch (armed until its last read is acked). The
	// arbiter's own pending flag drops between the sub-requests, so it uses
	// this to tell "mid-burst" from "idle".
	output        fetch_busy,

	// Ring-buffer occupancy, used by the arbiter to escalate rd2 priority
	// only when the buffer is close to underrunning.
	output  [3:0] rbuf_count_out,

	// Raster line, read by the slave Z80
	output  [7:0] raster_line
);

//------------------------------------------------------------------
// Timing counters
//   H: 0..319 active, 320..423 blanking, hsync 336..383
//   V: 0..239 active, 240..255 blanking, vsync 241..244
//------------------------------------------------------------------
localparam H_TOTAL  = 10'd424;
localparam H_ACTIVE = 10'd320;
localparam H_SYNC_S = 10'd336;
localparam H_SYNC_E = 10'd384;

localparam V_TOTAL  = 9'd256;
localparam V_ACTIVE = 9'd240;
localparam V_SYNC_S = 9'd241;
localparam V_SYNC_E = 9'd245;

reg  [9:0] hc;   // horizontal pixel counter
reg  [8:0] vc;   // vertical line counter

always @(posedge clk_sys) begin
	if (reset_cnt) begin
		hc <= 0;
		vc <= 0;
	end else if (ce_pix) begin
		if (hc == H_TOTAL - 1'd1) begin
			hc <= 0;
			vc <= (vc == V_TOTAL - 1'd1) ? 9'd0 : vc + 1'd1;
		end else begin
			hc <= hc + 1'd1;
		end
	end
end

// The scroll registers are used live, not latched per frame: MAME's
// scroll_w() calls update_partial() first, so the game relies on mid-frame
// scroll changes (HUD/status split).

// hblank/hsync follow the pixel pipeline, in which the colour for hc = N is
// on rgb after the ce_pix that sees hc = N+1. The HBlank and HSync outputs take
// one more register stage so they change on the same ce_pix as rgb; without it
// the first picture pixel is blanked and the last one is cut off.
reg hblank_i, hsync_i;

always @(posedge clk_sys) begin
	if (ce_pix) begin
		hblank_i <= (hc >= H_ACTIVE);
		hsync_i  <= (hc >= H_SYNC_S) && (hc < H_SYNC_E);
		HBlank   <= hblank_i;
		HSync    <= hsync_i;
		VBlank   <= (vc >= V_ACTIVE);
		VSync    <= (vc >= V_SYNC_S) && (vc < V_SYNC_E);
	end
end

//------------------------------------------------------------------
// Foreground bitmap
// One byte holds two 4-bit pens ([7:4] even pixel, [3:0] odd pixel).
// Stride is 256 bytes per line (MAME: y << 8).
//------------------------------------------------------------------
assign vram_addr   = {1'b0, vc[7:0], hc[8:1]};
assign raster_line = vc[7:0];

reg  [7:0] vram_latch;
reg        hc_lsb;

always @(posedge clk_sys) begin
	if (ce_pix) begin
		vram_latch <= vram_data;
		hc_lsb     <= hc[0];
	end
end

wire [3:0] fg_pen = hc_lsb ? vram_latch[3:0] : vram_latch[7:4];

//------------------------------------------------------------------
// Background tilemap (MAME leland_get_tile_info / leland_scan)
//
// 256x256 tiles of 8x8 pixels, scrolled and wrapping. The PROM byte selects
// the tile and its colour; pixel data is three bitplanes in bg_gfx.
//------------------------------------------------------------------
wire [10:0] eff_x = hc[9:0] + scroll_x[10:0];
wire [10:0] eff_y = {2'b0, vc} + scroll_y[10:0];
wire  [2:0] col_in_tile = eff_x[2:0];

// leland_scan: idx = (col&0xff) | ((row&0x1f)<<8) | ((row&0xe0)<<9)
function automatic [16:0] leland_tile_idx(input [7:0] col, input [7:0] row);
	leland_tile_idx = {row[7:5], 1'b0, row[4:0], col};
endfunction

// Fetch state for the tile row being produced
reg [3:0] fetch_ph;
reg [7:0] fetch_col, fetch_row;
reg [2:0] fetch_riy;      // row-in-tile of the target pixel, latched at arm
                          // time (a row-start arm happens before vc increments)
reg [7:0] prom_byte_next;

// fetch_ph: odd/named REQ states hold sdram_rd2_req_r high until the ack
// arrives (a real handshake; latency varies with arbitration).
localparam FP_IDLE        = 4'd0,
           FP_PROM_LOOKUP = 4'd7, // present the index to the line-cache RAM
           FP_PROM_REQ    = 4'd1, FP_PROM_WAIT   = 4'd2,
           FP_GFX_LOOKUP  = 4'd3, // present the index to the gfx cache RAM
           FP_GFXROW_REQ  = 4'd4, // cache data valid: check hit/miss
           FP_GFXROW_WAIT = 4'd5,
           FP_GFXCACHED   = 4'd6, // cache hit: push next cycle, no SDRAM
           FP_Q0          = 4'd8, // Ataxx: present the low tile-code address
           FP_Q1          = 4'd9, // capture low byte, present the high address
           FP_Q2          = 4'd10; // capture high byte, form the tile code

// Displayed tile
reg [7:0] bg_color_cur;
// Named by which third of bg_gfx they came from (see bg_pen below)
reg [7:0] bg_third0_cur, bg_third1_cur, bg_third2_cur;
reg [7:0] bg_third3_cur, bg_third4_cur, bg_third5_cur; // Ataxx planes 3-5

//------------------------------------------------------------------
// Tile prefetch ring buffer
//
// One SDRAM round trip takes 40-79 clk_sys cycles and a tile row needs up to
// two, far more than the 8 pixels (~54 cycles) between tile boundaries. So a
// producer (the fetch_ph FSM below) runs several tiles ahead of the display
// and fills an 8-deep ring buffer; the display just pops the next entry at
// each tile boundary. An empty buffer holds the previous tile.
//------------------------------------------------------------------
localparam RBUF_N = 4'd8;
reg [7:0] rbuf_color [0:7];   // only [7:5] meaningful (PROM colour bits)
reg [7:0] rbuf_third0[0:7];
reg [7:0] rbuf_third1[0:7];
reg [7:0] rbuf_third2[0:7];
reg [7:0] rbuf_third3[0:7];   // Ataxx only
reg [7:0] rbuf_third4[0:7];
reg [7:0] rbuf_third5[0:7];
reg [2:0] rbuf_wr, rbuf_rd;   // wrap naturally at 8
reg [3:0] rbuf_count;
assign rbuf_count_out = rbuf_count;

wire [7:0] rbuf_color_rd  = rbuf_color [rbuf_rd];
wire [7:0] rbuf_third0_rd = rbuf_third0[rbuf_rd];
wire [7:0] rbuf_third1_rd = rbuf_third1[rbuf_rd];
wire [7:0] rbuf_third2_rd = rbuf_third2[rbuf_rd];
wire [7:0] rbuf_third3_rd = rbuf_third3[rbuf_rd];
wire [7:0] rbuf_third4_rd = rbuf_third4[rbuf_rd];
wire [7:0] rbuf_third5_rd = rbuf_third5[rbuf_rd];
wire       rbuf_has_data  = (rbuf_count != 4'd0);
wire       rbuf_has_room  = (rbuf_count != RBUF_N);

// The producer's walk cursor: position of the most recently queued tile.
// With entries queued each arm continues from it, one tile further ahead;
// with an empty buffer it resyncs to the live display position.
reg [9:0] walk_hc;
reg [8:0] walk_vc;

// Forces one resync to the live position per display row, so any miscount
// is corrected within a row instead of persisting.
reg [8:0] row_resync_vc_r;
reg       row_resync_pending;

// A scroll change makes everything queued or in flight stale: the tiles were fetched with
// the old scroll, and the HUD split switches it mid-frame. The queue is emptied and the
// fetch in flight is dropped when it arrives, so the producer refetches from the live
// position with the new scroll.
reg [15:0] scroll_x_q, scroll_y_q;
reg        flush_pend;
reg        fetch_stale;

wire [11:0] fetch_tile_code = {gfxbank[5:4], fetch_row[7:6], prom_byte_next};

// SDRAM addresses of this tile's PROM byte and packed gfx row. gfxbank[3]
// selects the PROM's second 8 KB bank.
wire [16:0] prom_offset = leland_tile_idx(fetch_col, fetch_row) | {3'b0, gfxbank[3], 13'b0};
wire [24:0] prom_sdram_addr = ADDR_PROM_BASE[24:0] + {8'b0, prom_offset};

// Planes 0-2 of a tile row are pre-packed by the board's repack FSM at
// ADDR_GFXROW_BASE (word 0 = {plane1, plane0}, word 1 = {8'h00, plane2}) so
// one 2-word burst returns all three.
wire [14:0] gfx01_idx = {fetch_tile_code, fetch_riy};
wire [24:0] gfxrow_sdram_addr = ADDR_GFXROW_BASE[24:0] + {gfx01_idx, 2'b00};

//------------------------------------------------------------------
// Tile-row gfx cache
//
// 256-entry direct-mapped cache over gfx01_idx holding all three plane bytes,
// so a hit skips the SDRAM burst. gfxbank[5:4] is folded into the tile code,
// and bg_gfx is read-only for the session, so entries never go stale.
// Entry = {valid, tag[6:0], plane0, plane1, plane2}. Block RAM has no
// per-bit clear, so reset invalidates by writing zero to each address.
//------------------------------------------------------------------
localparam [31:0] GFXCACHE_INVALID = 32'd0;
reg [31:0] gfxcache_mem [0:255];
reg  [7:0] gfxcache_clear_idx;
reg        gfxcache_wr_en;
reg  [7:0] gfxcache_wr_addr;
reg [31:0] gfxcache_wr_data;
reg [31:0] gfxcache_rd_data_r;

wire [7:0] gfx_cache_idx = gfx01_idx[7:0];
wire [6:0] gfx_cache_tag = gfx01_idx[14:8];
wire       gfx_cache_hit  = gfxcache_rd_data_r[31] && (gfxcache_rd_data_r[30:24] == gfx_cache_tag);
wire [7:0] gfxcache_b0_rd = gfxcache_rd_data_r[23:16];
wire [7:0] gfxcache_b1_rd = gfxcache_rd_data_r[15:8];
wire [7:0] gfxcache_b2_rd = gfxcache_rd_data_r[7:0];

always @(posedge clk_sys) begin
	if (reset) begin
		gfxcache_clear_idx <= (gfxcache_clear_idx == 8'hFF) ? gfxcache_clear_idx : (gfxcache_clear_idx + 8'd1);
		gfxcache_mem[gfxcache_clear_idx] <= GFXCACHE_INVALID;
	end else begin
		gfxcache_clear_idx <= 8'd0;
		if (gfxcache_wr_en) gfxcache_mem[gfxcache_wr_addr] <= gfxcache_wr_data;
	end
	// Registered read: the index presented in FP_GFX_LOOKUP is valid in
	// gfxcache_rd_data_r during FP_GFXROW_REQ.
	gfxcache_rd_data_r <= gfxcache_mem[gfx_cache_idx];
end

reg         sdram_rd2_req_r;
reg  [24:0] sdram_rd2_addr_r;
assign sdram_rd2_req  = sdram_rd2_req_r;
assign sdram_rd2_addr = sdram_rd2_addr_r;

//------------------------------------------------------------------
// Fetch target
//
// A tile queued now is displayed 8 pixels after the position it is armed
// from (commit_pos = base_hc + 8). Where commit_pos lands decides the target:
//   active   (commit_pos < H_ACTIVE):  hc + 8 on the current row
//   blanking (H_ACTIVE <= commit_pos < H_TOTAL): the commit is invisible; the
//            only visible use is the start of the next row, so target (0, vc+1)
//   wrapped  (commit_pos >= H_TOTAL):  lands at commit_pos - H_TOTAL on the
//            next row (the blanking is longer than the lead, so a commit can
//            wrap at most once)
//
// base_hc/base_vc is the position the next arm is 8 pixels ahead of:
//   empty buffer                      -> live display position
//   entries queued, no pending resync -> the walk cursor
//   entries queued, resync pending    -> the boundary of the last queued entry
// (the buffer is normally full when a row starts, so a bare resync to hc would
// place the new tile 8*rbuf_count pixels too early). The first queued entry
// pops at the next tile boundary, hc + ((8 - col_in_tile) & 7), and the rest
// follow 8 pixels apart. The result is boundary-aligned like the walk cursor;
// an unaligned base shifts every later commit and can push the partial tile at
// the right edge of the row into the blanking case.
//------------------------------------------------------------------
wire  [2:0] col_to_boundary = 3'd0 - col_in_tile;
wire  [9:0] resync_hc = hc + {7'd0, col_to_boundary} + {rbuf_count - 4'd1, 3'd0};
wire  [9:0] base_hc = (rbuf_has_data && !row_resync_pending) ? walk_hc :
                      rbuf_has_data ? resync_hc : hc;
wire  [8:0] base_vc = (rbuf_has_data && !row_resync_pending) ? walk_vc : vc;

wire  [9:0] commit_pos      = base_hc + 10'd8;
wire        commit_wraps    = (commit_pos >= H_TOTAL);
wire        commit_in_blank = !commit_wraps && (commit_pos >= H_ACTIVE);
wire  [9:0] hc_tgt  = commit_wraps    ? (commit_pos - H_TOTAL) :
                      commit_in_blank ? 10'd0 : commit_pos;
wire  [8:0] vc_tgt  = (commit_wraps || commit_in_blank)
                      ? ((base_vc == V_TOTAL - 1'd1) ? 9'd0 : base_vc + 1'd1) : base_vc;
wire [10:0] eff_x_tgt = hc_tgt + scroll_x[10:0];
wire [10:0] eff_y_tgt = {2'b0, vc_tgt} + scroll_y[10:0];
wire  [7:0] tile_col_tgt = eff_x_tgt[10:3];
wire  [7:0] tile_row_tgt = eff_y_tgt[10:3];

// What the walk cursor stores for the next step. It differs from hc_tgt only
// in the blanking case. With a fine scroll_x offset the first tile of the new
// row is a partial one covering hc = 0 .. 7-fine, and the next boundary is at
// hc = 8-fine, so the cursor steps back to -fine (mod 1024) and the following
// commit (+8) lands on that boundary.
wire [2:0] scroll_x_fine      = scroll_x[2:0];
wire [9:0] blank_wrap_next_hc = 10'd0 - {7'd0, scroll_x_fine};
wire [9:0] walk_hc_store = commit_in_blank ? blank_wrap_next_hc : hc_tgt;

//------------------------------------------------------------------
// PROM line cache
//
// One entry per tile column, tagged {gfxbank[3], row}: a tile is revisited on
// each of its 8 scanlines but only after ~40 other columns, so a single-entry
// cache never hits. The PROM is read-only for the session, so no
// invalidation is needed. The read address is the live tile_col_tgt, so
// prom_lc_q holds mem[fetch_col] during FP_PROM_LOOKUP. Valid bits are flops
// so reset clears all 256 at once (RAM contents are undefined at power-up).
//------------------------------------------------------------------
localparam integer PROM_LC_N = 256;
reg [16:0]           prom_lc_mem [0:PROM_LC_N-1]; // {bank3, row[7:0], byte[7:0]}
reg [16:0]           prom_lc_q;
reg [PROM_LC_N-1:0]  prom_lc_valid;

wire prom_lc_hit = prom_lc_valid[fetch_col]
                  && (prom_lc_q[16]   == gfxbank[3])
                  && (prom_lc_q[15:8] == fetch_row);

wire prom_lc_fill = (fetch_ph == FP_PROM_WAIT) && sdram_rd2_ack;

always @(posedge clk_sys) begin
	if (prom_lc_fill) prom_lc_mem[fetch_col] <= {gfxbank[3], fetch_row, sdram_rd2_data};
	prom_lc_q <= prom_lc_mem[tile_col_tgt];
end

always @(posedge clk_sys) begin
	if (reset)             prom_lc_valid <= '0;
	else if (prom_lc_fill) prom_lc_valid[fetch_col] <= 1'b1;
end

//------------------------------------------------------------------
// Ataxx tile fetch (ataxx_mode): the tile code comes from the tile RAM and each tile
// row is one 4-word burst from the MRA's interleave (bytes plane0..plane5, then 2 pad).
// A 1024-entry direct-mapped row cache keyed by {code, row-in-tile} skips the burst on
// a hit. Entry = {valid, tag[7:0], plane0 .. plane5}.
//------------------------------------------------------------------
reg  [7:0]  ax_lo;
reg [14:0]  ax_code;
wire [17:0] ax_idx  = {ax_code, fetch_riy};
wire  [9:0] ax_cidx = ax_idx[9:0];
wire  [7:0] ax_ctag = ax_idx[17:10];
wire [24:0] ax_row_addr = ADDR_GFX_BASE[24:0] + {2'b0, ax_idx, 3'b000};

// Low tile byte at index, high byte at index | 0x4000 (MAME ataxx_get_tile_info)
assign qram_addr = {fetch_row[6], (fetch_ph == FP_Q1), fetch_row[5:0], fetch_col};

reg [56:0] axcache_mem [0:1023];
reg  [9:0] axcache_clear_idx;
reg        axcache_wr_en;
reg  [9:0] axcache_wr_addr;
reg [56:0] axcache_wr_data;
reg [56:0] axcache_rd_r;
wire       ax_hit = axcache_rd_r[56] && (axcache_rd_r[55:48] == ax_ctag);

always @(posedge clk_sys) begin
	if (reset) begin
		axcache_clear_idx <= (axcache_clear_idx == 10'h3FF) ? axcache_clear_idx : (axcache_clear_idx + 10'd1);
		axcache_mem[axcache_clear_idx] <= 57'd0;
	end else begin
		axcache_clear_idx <= 10'd0;
		if (axcache_wr_en) axcache_mem[axcache_wr_addr] <= axcache_wr_data;
	end
	axcache_rd_r <= axcache_mem[ax_cidx];
end

assign fetch_busy = (fetch_ph != FP_IDLE);

// A push (fetch complete) and a pop (tile boundary) are evaluated
// independently every cycle and may coincide.
//
// Pops are limited to the 320 active pixels (hc = 0, 8, ..., 312). The
// col_in_tile==0 event also fires through the ~104 pixels of blanking, and
// because the producer chains forward from its walk cursor each of those
// would drain a distinct future tile, letting the cursor run away from the
// display.
//
// With scroll_x not a multiple of 8 a row touches 41 tiles: a partial tile
// covering hc = 0 .. 7-fine, then 40 more from hc = 8-fine. The extra pop at
// hc == 0 picks up that partial tile; when fine == 0 hc == 0 is already a tile
// boundary and pops once.
wire fifo_push    = (((fetch_ph == FP_GFXROW_WAIT) && sdram_rd2_ack) || (fetch_ph == FP_GFXCACHED)) && !fetch_stale;
wire fifo_pop_req = ce_pix && ((col_in_tile == 3'd0) || (hc == 10'd0)) && (hc < H_ACTIVE);
wire fifo_pop     = fifo_pop_req && rbuf_has_data;

always @(posedge clk_sys) begin
	if (reset) begin
		fetch_ph         <= FP_IDLE;
		sdram_rd2_req_r  <= 1'b0;
		rbuf_wr          <= 3'd0;
		rbuf_rd          <= 3'd0;
		rbuf_count       <= 4'd0;
		gfxcache_wr_en   <= 1'b0;
		axcache_wr_en    <= 1'b0;
		row_resync_vc_r    <= 9'd0;
		row_resync_pending <= 1'b1;
		flush_pend         <= 1'b0;
		fetch_stale        <= 1'b0;
	end else begin
		gfxcache_wr_en   <= 1'b0;
		axcache_wr_en    <= 1'b0;

		// A new display row forces one resync to the live position
		if (vc != row_resync_vc_r) begin
			row_resync_vc_r    <= vc;
			row_resync_pending <= 1'b1;
		end

		// Producer: whenever the FSM is idle and there is room, arm the next
		// tile. Always spend one cycle in FP_PROM_LOOKUP so the registered
		// line-cache read is valid; that replaces an SDRAM round trip on a hit.
		if ((fetch_ph == FP_IDLE) && rbuf_has_room) begin
			fetch_col <= tile_col_tgt;
			fetch_row <= ataxx_mode ? {1'b0, tile_row_tgt[6:0]} : tile_row_tgt;
			fetch_riy <= eff_y_tgt[2:0];
			walk_hc   <= walk_hc_store;
			walk_vc   <= vc_tgt;
			row_resync_pending <= 1'b0;
			fetch_ph  <= ataxx_mode ? FP_Q0 : FP_PROM_LOOKUP;
		end

		// Consumer: pop the next tile at the start of its display window
		if (fifo_pop_req && rbuf_has_data) begin
			bg_color_cur   <= rbuf_color_rd[7:5];
			bg_third0_cur  <= rbuf_third0_rd;
			bg_third1_cur  <= rbuf_third1_rd;
			bg_third2_cur  <= rbuf_third2_rd;
			bg_third3_cur  <= rbuf_third3_rd;
			bg_third4_cur  <= rbuf_third4_rd;
			bg_third5_cur  <= rbuf_third5_rd;
		end

		if (fifo_push && !fifo_pop) rbuf_count <= rbuf_count + 4'd1;
		else if (!fifo_push && fifo_pop) rbuf_count <= rbuf_count - 4'd1;
		if (fifo_push) rbuf_wr <= rbuf_wr + 3'd1;
		if (fifo_pop)  rbuf_rd <= rbuf_rd + 3'd1;

		// Flush on a cycle with no push or pop so the counters are not updated twice
		scroll_x_q <= scroll_x;
		scroll_y_q <= scroll_y;
		if (fetch_ph == FP_IDLE) fetch_stale <= 1'b0;
		if (flush_pend && !fifo_push && !fifo_pop) begin
			flush_pend         <= 1'b0;
			rbuf_count         <= 4'd0;
			rbuf_wr            <= rbuf_rd;
			row_resync_pending <= 1'b1;
			if (fetch_ph != FP_IDLE) fetch_stale <= 1'b1;
		end
		if ((scroll_x != scroll_x_q) || (scroll_y != scroll_y_q)) flush_pend <= 1'b1;

		case (fetch_ph)
			FP_Q0: fetch_ph <= FP_Q1;
			FP_Q1: begin
				ax_lo    <= qram_data;
				fetch_ph <= FP_Q2;
			end
			FP_Q2: begin
				ax_code  <= {qram_data[6] & gfx_wide, qram_data[5:0], ax_lo};
				fetch_ph <= FP_GFX_LOOKUP;
			end
			FP_PROM_LOOKUP: begin
				if (prom_lc_hit) begin
					prom_byte_next <= prom_lc_q[7:0];
					fetch_ph       <= FP_GFX_LOOKUP;
				end else begin
					fetch_ph       <= FP_PROM_REQ;
				end
			end
			FP_PROM_REQ: begin
				sdram_rd2_addr_r <= prom_sdram_addr;
				sdram_rd2_req_r  <= 1'b1;
				fetch_ph         <= FP_PROM_WAIT;
			end
			FP_PROM_WAIT: if (sdram_rd2_ack) begin
				prom_byte_next   <= sdram_rd2_data;
				sdram_rd2_req_r  <= 1'b0;
				fetch_ph         <= FP_GFX_LOOKUP;
			end
			FP_GFX_LOOKUP: begin
				fetch_ph <= FP_GFXROW_REQ;
			end
			FP_GFXROW_REQ: begin
				if (ataxx_mode ? ax_hit : gfx_cache_hit) begin
					fetch_ph <= FP_GFXCACHED;
				end else begin
					sdram_rd2_addr_r <= ataxx_mode ? ax_row_addr : gfxrow_sdram_addr;
					sdram_rd2_req_r  <= 1'b1;
					fetch_ph         <= FP_GFXROW_WAIT;
				end
			end
			FP_GFXROW_WAIT: if (sdram_rd2_ack) begin
				// Both burst words are valid on the ack cycle
				rbuf_color [rbuf_wr] <= prom_byte_next;
				rbuf_third0[rbuf_wr] <= sdram_rd2_data16[7:0];
				rbuf_third1[rbuf_wr] <= sdram_rd2_data16[15:8];
				rbuf_third2[rbuf_wr] <= sdram_rd2_data16_hi[7:0];
				rbuf_third3[rbuf_wr] <= sdram_rd2_data16_hi[15:8];
				rbuf_third4[rbuf_wr] <= sdram_rd2_data16_w2[7:0];
				rbuf_third5[rbuf_wr] <= sdram_rd2_data16_w2[15:8];
				axcache_wr_en    <= ataxx_mode;
				axcache_wr_addr  <= ax_cidx;
				axcache_wr_data  <= {1'b1, ax_ctag, sdram_rd2_data16[7:0], sdram_rd2_data16[15:8], sdram_rd2_data16_hi[7:0], sdram_rd2_data16_hi[15:8], sdram_rd2_data16_w2[7:0], sdram_rd2_data16_w2[15:8]};
				gfxcache_wr_en   <= ~ataxx_mode;
				gfxcache_wr_addr <= gfx_cache_idx;
				gfxcache_wr_data <= {1'b1, gfx_cache_tag, sdram_rd2_data16[7:0], sdram_rd2_data16[15:8], sdram_rd2_data16_hi[7:0]};
				sdram_rd2_req_r  <= 1'b0;
				fetch_ph         <= FP_IDLE;
			end
			FP_GFXCACHED: begin
				rbuf_color [rbuf_wr] <= prom_byte_next;
				rbuf_third0[rbuf_wr] <= ataxx_mode ? axcache_rd_r[47:40] : gfxcache_b0_rd;
				rbuf_third1[rbuf_wr] <= ataxx_mode ? axcache_rd_r[39:32] : gfxcache_b1_rd;
				rbuf_third2[rbuf_wr] <= ataxx_mode ? axcache_rd_r[31:24] : gfxcache_b2_rd;
				rbuf_third3[rbuf_wr] <= axcache_rd_r[23:16];
				rbuf_third4[rbuf_wr] <= axcache_rd_r[15:8];
				rbuf_third5[rbuf_wr] <= axcache_rd_r[7:0];
				fetch_ph             <= FP_IDLE;
			end
			default: ;
		endcase
	end
end

//------------------------------------------------------------------
// Background pixel
//
// Bit order: MAME's leland_layout uses xoffset STEP8(0,1), which its decoder
// reads MSB-first, so pixel column 0 is bit 7 of the plane byte.
//
// Pipeline alignment: every other pixel-path signal is one ce_pix behind hc,
// so the bit index uses a one-ce_pix-delayed col_in_tile. With the live value
// the first pixel of every tile showed the previous tile's last column.
//------------------------------------------------------------------
reg [2:0] col_in_tile_d;
always @(posedge clk_sys) if (ce_pix) col_in_tile_d <= col_in_tile;

// Plane weights are reversed relative to bg_gfx ROM order: MAME's
// leland_layout lists its plane offsets ascending, and the decoder gives
// plane offset 0 the most significant bit. So the first third of bg_gfx (u93)
// is pixel bit 2 and the last (u95) is bit 0.
wire bg_third0 = bg_third0_cur[3'd7 - col_in_tile_d];  // u93 -> pixel bit 2
wire bg_third1 = bg_third1_cur[3'd7 - col_in_tile_d];  // u94 -> pixel bit 1
wire bg_third2 = bg_third2_cur[3'd7 - col_in_tile_d];  // u95 -> pixel bit 0
// Ataxx: six planes, plane 0 (the first ROM file) is the pen's LSB (verified against the
// palette: board tiles decode to pens 1-11, the teal ramp, only in this order)
wire [5:0] ax_pen = {bg_third5_cur[3'd7 - col_in_tile_d], bg_third4_cur[3'd7 - col_in_tile_d],
                     bg_third3_cur[3'd7 - col_in_tile_d], bg_third2_cur[3'd7 - col_in_tile_d],
                     bg_third1_cur[3'd7 - col_in_tile_d], bg_third0_cur[3'd7 - col_in_tile_d]};
wire [5:0] bg_pen = ataxx_mode ? ax_pen : {bg_color_cur[2:0], bg_third0, bg_third1, bg_third2};

//------------------------------------------------------------------
// Palette lookup and BGR 2-3-3 -> RGB 8-8-8 expansion (MSB replication)
//------------------------------------------------------------------
assign cram_addr = {fg_pen, bg_pen};

wire [7:0] col_r = {cram_data[2:0], cram_data[2:0], cram_data[2:1]};
wire [7:0] col_g = {cram_data[5:3], cram_data[5:3], cram_data[5:4]};
wire [7:0] col_b = {cram_data[7:6], cram_data[7:6], cram_data[7:6], cram_data[7:6]};

// Ataxx palette: 16-bit xRGB-444 words, low byte (GB) at the even address. The pen is
// stable for the whole pixel, so the two bytes are read back to back after each ce_pix.
reg [2:0] pal_ph;
reg [7:0] pal_lo, pal_hi;
always @(posedge clk_sys) begin
	if (ce_pix)               pal_ph <= 3'd0;
	else if (pal_ph != 3'd7)  pal_ph <= pal_ph + 3'd1;
	if (pal_ph == 3'd1) pal_lo <= pal_data;
	if (pal_ph == 3'd2) pal_hi <= pal_data;
end
assign pal_addr = {fg_pen, bg_pen, (pal_ph == 3'd1)};

wire [7:0] ax_r = {pal_hi[3:0], pal_hi[3:0]};
wire [7:0] ax_g = {pal_lo[7:4], pal_lo[7:4]};
wire [7:0] ax_b = {pal_lo[3:0], pal_lo[3:0]};

always @(posedge clk_sys) begin
	if (ce_pix) begin
		if (hblank_i || VBlank)  rgb <= 24'd0;
		else if (ataxx_mode)   rgb <= {ax_r, ax_g, ax_b};
		else                   rgb <= {col_r, col_g, col_b};
	end
end

endmodule
