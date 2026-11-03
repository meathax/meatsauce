`timescale 1ns/1ps
//============================================================================
//  Xybots — SP-313 sheets 5 and 6: the motion-object table walk, the object
//  word latches, the vertical match pipeline, the sprite-ROM address and the
//  pixel path (LS158 swap + LS194 shifters).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  Everything here is phase-locked to h[2:0].  The sheet's latch clocks map
//  onto those counts like this:
//
//   h%8 | VRAM phase | what happens
//   ----+------------+--------------------------------------------------------
//    0  | MO word 2  | (fetch)                       entry n = H[8:3]
//    1  | MO word 0  | word 2 latched (10F/9E LS174A rises at h%8 == 1)
//    2  | CPU        | word 0 latched (6F/6E LS273B on /4HD2H, rises at 2)
//    3  | ALPHA      |
//    4  | PLAYFIELD  |
//    5  | MO word 1  |
//    6  | CPU        | word 1 latched (8E LS174B on 4HD2H, rises at 6);
//       |            | 1D LS174C + 5F/5E LS273F take /MOVMATCH, MOHFLIP and
//       |            | the ROM address for entry n
//    7  | MO word 3  | /MOHLD loads the line buffer's write pointer from
//       |            | SCRAMD15:7 straight off the video bus
//   ----+------------+--------------------------------------------------------
//   then, in the NEXT eight-pixel period, entry n's eight pixels are shifted
//   out: MOCOL (7E LS175 on /4H) and MOPRI (8F LS175 on /4H) come valid at
//   h%8 == 0 with them, and the LS194 pair reloads every two pixels.
//
//  So entry n is FETCHED over h = 8n .. 8n+7 and DRAWN over h = 8n+8 .. 8n+15.
//  The line-buffer write window is h = 8 .. 455 (sheet 8, /DIE gated by
//  1VD8H), so entries 0..55 are drawn, entry 56 is fetched and thrown away,
//  and entries 57..63 are never addressed at all.
//
//  ---------------------------------------------------------------------------
//  THE ONE PLACE THIS IS NOT GATE-FOR-GATE
//  ---------------------------------------------------------------------------
//  The board reads the sprite ROMs CONTINUOUSLY: 5F/5E hold MOA12..MOA2 for
//  eight pixels while 7F LS86 walks A1/A0 (= /4HD2H ^ MOHFLIPD, /2H ^ MOHFLIPD)
//  through the four bytes of the tile row, two pixels per byte.  Here the row
//  is a single 4-byte SDRAM burst, so:
//
//    * the request is issued at h%8 == 1, the moment word 0 arrives, using the
//      combinational sheet-5 address — six pixels = 48 clk_sys before the row
//      is needed, against a 31 clk_sys worst-case client latency;
//    * the 32-bit result replaces 5F/5E; A1/A0 still select the byte exactly as
//      7F LS86 does, so the flip and the two-pixels-per-byte cadence are
//      unchanged;
//    * 1D/5F/5E are modelled by ONE register loaded at h%8 == 7 rather than the
//      sheet's h%8 == 5, with the h%8 == 7 pixel itself reading the fetch
//      register directly.  The LS194 pair only loads on odd h and the byte it
//      wants at h%8 == 7 is byte 0 of the burst, so nothing observable moves —
//      and the client gets two more pixels of slack than the sheet's own
//      pipeline would allow.
//
//  No request is issued for an entry whose vertical match fails, which is why
//  the SDRAM load is "columns per scanline" and not one fetch per entry: over
//  3,596 captured frames the worst line asked for 45 rows of the 64 possible.
//============================================================================

module xybots_mo_fetch (
	input  logic        clk,          // clk_sys, 57.272727 MHz
	input  logic        reset,        // synchronous, active high
	input  logic        ce_7m,        // the LAST clk_sys cycle of each pixel

	// ---- SYNGEN (sheet 4) ----
	input  logic [8:0]  h,            // 1H..256H
	input  logic [7:0]  v,            // 1V..128V
	input  logic        vblank,       // 9F LS04 — the 9th vertical bit into 10D
	input  logic        h_2hd1h,      // 11J 74S04 (9->8)
	input  logic        h_4hd2h_n,    // SYNGEN pin 36 = /4HD2H

	// ---- video-side VRAM port (sheet 5 LS253 mux, MO phase) ----
	output logic [12:0] vram_vaddr,   // word address; valid every MO phase
	input  logic [15:0] scram_d,      // SCRAMD15:0, at the ce_7m of that pixel

	// ---- sprite ROM client (xybots_gfx_mem, reached through xybots_mem) ----
	output logic        mo_req,
	output logic [18:2] mo_addr,
	input  logic        mo_valid,
	input  logic [31:0] mo_data,      // {b3,b2,b1,b0}; b0 is the (A1,A0)=00 byte

	// ---- to the line buffers (sheet 8), all in the INVERTED sense ----
	output logic [3:0]  mopix,        // 6K/5K LS194 QD,QC — ~pen
	output logic [3:0]  mocol,        // 7E LS175 /Q       — ~colour
	output logic [3:0]  mopri,        // 8F LS175 /Q       — ~priority

	// ---- diagnostic: driven, but nothing in the core reads it ----
	output logic        fetch_late    // sticky: ROM data missed its deadline
);

	wire [2:0] hp = h[2:0];

	// =====================================================================
	// 1. The sheet-5 LS253 address mux, motion-object phase
	// =====================================================================
	// {1,0,1,1,1, 256H..8H, 2HD1H, 4H} = words 0x1700..0x17FF = bytes
	// 0x802E00..0x802FFF.  {2HD1H,4H} sweeps 2,0,1,3 over h%8 = 0,1,5,7.
	assign vram_vaddr = {5'b10111, h[8:3], h_2hd1h, h[2]};

	// =====================================================================
	// 2. Object word latches
	// =====================================================================
	// Only the fields that are wired are kept; word 0 bit 14 and word 2 bits
	// 6..3 have no latch output on the sheet.
	logic [8:0]  mov_q;      // 10F/9E LS174A — word 2 [15:7]
	logic [2:0]  movsiz_q;   // 10F/9E LS174A — word 2 [2:0]
	logic [13:0] mopic_q;    // 6F/6E LS273B  — word 0 [13:0]
	logic        mohflip_q;  // 6F 13->12     — word 0 [15]
	logic [3:0]  pri_8e;     // 8E LS174B     — word 1 [3:0], true sense

	always_ff @(posedge clk) begin
		if (reset) begin
			mov_q     <= '0;
			movsiz_q  <= '0;
			mopic_q   <= '0;
			mohflip_q <= 1'b0;
			pri_8e    <= '0;
			mocol     <= 4'hF;
			mopri     <= 4'hF;
		end else if (ce_7m) begin
			// word 2 at h%8 == 0, latched by the h%8 == 1 clock edge
			if (hp == 3'd0) begin
				mov_q    <= scram_d[15:7];
				movsiz_q <= scram_d[2:0];
			end
			// word 0 at h%8 == 1, latched on /4HD2H (rises at h%8 == 2)
			if (hp == 3'd1) begin
				mopic_q   <= scram_d[13:0];
				mohflip_q <= scram_d[15];
			end
			// word 1 at h%8 == 5, latched on 4HD2H (rises at h%8 == 6)
			if (hp == 3'd5) pri_8e <= scram_d[3:0];
			// word 3 at h%8 == 7: 7E LS175 and 8F LS175 both clock on /4H,
			// which rises at h%8 == 0 — the first pixel of the draw window.
			// Both take their INVERTED outputs.
			if (hp == 3'd7) begin
				mocol <= ~scram_d[3:0];
				mopri <= ~pri_8e;
			end
		end
	end

	// =====================================================================
	// 3. Vertical match and the ROM address (sheet 5, combinational)
	// =====================================================================
	// The operand is {VBLANK, 128V..1V}: there is no 256V net on the board.
	// On a visible line that is simply MAME's vpos; on the last line of the
	// frame (v256 phase, v = 255, VBLANK = 1) it is 511, and 511 + 1 = 0 mod
	// 512 — which is exactly the display line the buffer written there feeds.
	wire [8:0] vop = {vblank, v};

	wire        vm_match;
	wire [2:0]  vm_moa;
	wire [13:0] vm_rom_tile;
	// 3D's S3..S1 leave the sheet only through 4D's B inputs, which are inside
	// xybots_mo_vmatch, so this copy of the tile row has no consumer here.  It
	// is brought out of the adder so a simulation can observe it directly.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [2:0]  vm_tile_row;
	/* verilator lint_on UNUSEDSIGNAL */

	// The adder chain sees word 0 the moment it arrives (h%8 == 1) so that the
	// SDRAM request can be issued a whole pixel earlier than the sheet's
	// 5F/5E pipeline would allow.  Word 2 is already latched by then.
	wire [13:0] mopic_now = (ce_7m && (hp == 3'd1)) ? scram_d[13:0] : mopic_q;

	xybots_mo_vmatch u_vmatch (
		.mov      (mov_q),
		.movsiz   (movsiz_q),
		.mopic    (mopic_now),
		.vop      (vop),
		.movmatch (vm_match),
		.tile_row (vm_tile_row),
		.moa      (vm_moa),
		.rom_tile (vm_rom_tile)
	);

	// =====================================================================
	// 4. Sprite-ROM client
	// =====================================================================
	// Byte address = {MOPIC13:8, MOA12:5, MOA4:2, A1, A0} = tile*32 + row*4.
	// The client takes bits [18:2] and returns the four bytes of that row.
	logic [31:0] rom_word_fetched;
	logic        rom_rdy;
	logic        rom_pending;

	always_ff @(posedge clk) begin
		if (reset) begin
			mo_req           <= 1'b0;
			mo_addr          <= '0;
			rom_word_fetched <= '0;
			rom_rdy          <= 1'b0;
			rom_pending      <= 1'b0;
			fetch_late       <= 1'b0;
		end else begin
			// one request per matching column; the arbiter waits for the drop
			if (mo_valid) begin
				rom_word_fetched <= mo_data;
				mo_req           <= 1'b0;
				rom_rdy          <= 1'b1;
			end
			if (ce_7m && (hp == 3'd1)) begin
				rom_rdy     <= 1'b0;
				rom_pending <= vm_match;
				if (vm_match) begin
					mo_addr <= {vm_rom_tile, vm_moa};
					mo_req  <= 1'b1;
				end
			end
			// Deadline: the row has to be in by h%8 == 7, the pixel on which
			// the LS158 pair reads byte 0 for the LS194 load.
			if (ce_7m && (hp == 3'd7)) begin
				if (rom_pending && !rom_rdy) fetch_late <= 1'b1;
			end
		end
	end

	// =====================================================================
	// 5. The draw-side pipeline (1D LS174C + 5F/5E LS273F, sheet 5/6)
	// =====================================================================
	logic [31:0] rom_word_cur;
	logic        hflip_cur;
	logic        match_cur;

	always_ff @(posedge clk) begin
		if (reset) begin
			rom_word_cur <= '0;
			hflip_cur    <= 1'b0;
			match_cur    <= 1'b0;
		end else if (ce_7m && (hp == 3'd7)) begin
			rom_word_cur <= rom_word_fetched;
			hflip_cur    <= mohflip_q;
			match_cur    <= rom_pending;
		end
	end

	// At h%8 == 7 the LS158s read BYTE 0 — the first byte of the burst that has
	// just arrived — so that pixel takes the fetch register directly and the
	// hand-off register is loaded one pixel later.  That is what puts the
	// client's deadline six pixels (48 clk_sys) after the request instead of
	// five, and it changes nothing else: at h%8 == 6 the LS158 output is never
	// sampled (the LS194 pair only loads on odd h).
	wire [31:0] rom_word_now = (hp == 3'd7) ? rom_word_fetched : rom_word_cur;
	wire        hflip_now    = (hp == 3'd7) ? mohflip_q        : hflip_cur;
	wire        match_now    = (hp == 3'd7) ? rom_pending      : match_cur;

	// =====================================================================
	// 6. 7F LS86 + 6J/5J LS158 + 6K/5K LS194 (sheet 6)
	// =====================================================================
	// A1 = /4HD2H ^ MOHFLIPD, A0 = /2H ^ MOHFLIPD.  Unflipped, {A1,A0} runs
	// 0,0,1,1,2,2,3,3 over the eight draw pixels (it is 0 already at h%8 == 6);
	// flipped it runs 3,3,2,2,1,1,0,0 and the LS158 pair also swaps the two
	// nibbles inside each byte, so h-flip is a clean eight-pixel reversal.
	wire       a1  = h_4hd2h_n ^ hflip_now;
	wire       a0  = (~h[1])   ^ hflip_now;
	wire [4:0] bsh = {a1, a0, 3'b000};
	wire [7:0] mod = rom_word_now[bsh +: 8];

	// The LS158s are INVERTING and their /G is /MOVMATCHD: with no vertical
	// match every output is forced high, i.e. MOPIX = 4'hF = the transparent
	// pen, which is what stops 8D LS20 (sheet 8) from writing anything.
	wire [3:0] pix_first  = match_now ? ~(hflip_now ? mod[3:0] : mod[7:4]) : 4'hF;
	wire [3:0] pix_second = match_now ? ~(hflip_now ? mod[7:4] : mod[3:0]) : 4'hF;

	// 6K/5K LS194: reloaded on every odd h so the pair is presented over the
	// following two pixels, first pixel on the even count.
	logic [3:0] shift_a, shift_b;
	always_ff @(posedge clk) begin
		if (reset) begin
			shift_a <= 4'hF;
			shift_b <= 4'hF;
		end else if (ce_7m && h[0]) begin
			shift_a <= pix_first;
			shift_b <= pix_second;
		end
	end

	assign mopix = h[0] ? shift_b : shift_a;

endmodule
