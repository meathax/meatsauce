// ThunderJaws adaptation of Batman commit34783858f6e1511e299ef159d6316544934f8fb5.
// Donor source remains byte-preserved; target changes: docs/VIDEO_PORTING.md.
`timescale 1ns/1ps
//============================================================================
//  Batman playfield layer, instantiated twice: PF1 (P1BASE 0x2F0000, the
//  transparent foreground, MAME's `playfield2`) and PF2 (P2BASE 0x2F2000, the
//  opaque background, MAME's `playfield`).  PF1/PF2 is the VAD's numbering.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_pf.sv and skullxbo_pfhs.sv of the Skull &
//  Crossbones MiSTer core (GPL-3.0); see NOTICE.md.
//
//  64 x 64 map of 8 x 8, 4 bpp tiles, column-major (index = col * 64 + row).
//  Code word: bits 14-0 tile code (covers the whole 1 MB ROM, so no bank),
//  bit 15 horizontal flip; there is no vertical flip.  One attribute RAM
//  serves both layers: PF1 uses the high byte (colour 11-8, priority 13-12),
//  PF2 the low byte (colour 3-0, priority 5-4).  Each layer reads it at its
//  own tile index, because the two layers' coarse scroll differs.
//
//  The layer fetches LEAD tile columns ahead of the beam and holds one
//  video-RAM address per 8-pixel group, since the board's video RAM has one
//  slot per pixel shared by all layers, the MOB and the CPU.  The lookahead
//  wraps at the end of the line into the next line.  The pixel output is still
//  one pixel after `px`.
//
//  Stamp ROM: four bit planes read in parallel, byte = code * 8 + row, MSB is
//  the left pixel; `rom_group` = {plane3..plane0}.  MAME stores the region
//  inverted, and the MRA ships raw bytes, so ROM_INVERT applies the board's
//  inversion here (the playfield pen reaches GAL 9B active high).
//  `xscroll` for PF2 already includes PF1's fine scroll (batman_vad_regs).
//  XOFF defaults to 0; batman_video sets the offsets that match MAME's frames.
//============================================================================

module thunderjaws_pf #(
	parameter bit ATTR_HIGH_BYTE = 1'b0,   // 1 = PF1 (high byte), 0 = PF2 (low)
	parameter bit ROM_INVERT     = 1'b0,   // the board's stamp-ROM inversion
	parameter int XOFF           = 0,      // pixel offset, set by batman_video
	parameter int LEAD           = 4,      // tile columns of prefetch
	parameter int H_PIX          = 456     // pixels per line (H_TOTAL / 2)
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        flip_screen,
	input  logic        ce_7m,         // one pulse per pixel, at its end

	// ---- raster ------------------------------------------------------------
	input  logic  [8:0] px,            // display pixel 0..H_PIX-1
	input  logic  [8:0] line,          // display line
	input  logic  [8:0] line_next,     // the following line, wrapped at VLAST

	// ---- scroll, from the parameter-word decoder ---------------------------
	input  logic  [8:0] xscroll,
	input  logic  [8:0] yscroll,

	// ---- the base addresses, from VAD reg 08 -------------------------------
	input  logic [14:0] base_code,     // word index of P1BASE / P2BASE
	input  logic [14:0] base_attr,     // word index of PABASE

	// ---- the scheduled video-RAM port (batman_vram.sv) ---------------------
	// Both addresses are held for a whole 8-pixel group; the words come back
	// in that group's slots and are consumed at the next `adv`.
	output logic [14:0] code_a,
	output logic [14:0] attr_a,
	input  logic [15:0] code_q,
	input  logic [15:0] attr_q,

	// ---- the stamp ROM: four plane bytes per (code, row) --------------------
	output logic        rom_fetch,     // one clk pulse
	output logic [17:0] rom_addr,      // byte address of plane 0 inside `tiles`
	input  logic [31:0] rom_group,     // {bit3, bit2, bit1, bit0}
	input  logic        rom_valid,
	output logic        rom_late,      // a fetch issued with one outstanding

	// ---- the layer's pixel, one pixel after `px` ---------------------------
	output logic  [3:0] pen,
	output logic  [3:0] colour,
	output logic  [1:0] pri
);

	// =====================================================================
	// Display map coordinate (only its fine bits are used)
	// =====================================================================
	localparam logic [8:0] XOFFV = XOFF[8:0];
	wire [8:0] source_x = flip_screen ? 9'd335-px : px;
	wire [8:0] mx = source_x + xscroll + XOFFV;
	wire [2:0] fine_x = mx[2:0];

	// A one-pixel scroll change can leave the source coordinate unchanged on
	// consecutive output pixels. It is still the same tile boundary, not a
	// second column to shift into the pipeline.
	logic prior_pixel_valid, prior_flip;
	logic [8:0] prior_mx, prior_line, prior_yscroll;
	logic [14:0] prior_base_code, prior_base_attr;
	always_ff @(posedge clk) begin
		if (reset) prior_pixel_valid <= 1'b0;
		else if (ce_7m) begin
			prior_pixel_valid <= 1'b1;
			prior_mx <= mx;
			prior_line <= line;
			prior_yscroll <= yscroll;
			prior_flip <= flip_screen;
			prior_base_code <= base_code;
			prior_base_attr <= base_attr;
		end
	end
	wire repeated_pixel = prior_pixel_valid && mx == prior_mx && line == prior_line &&
	                      yscroll == prior_yscroll && flip_screen == prior_flip &&
	                      base_code == prior_base_code && base_attr == prior_base_attr;
	// Group boundary: the last distinct source pixel in this tile column.
	wire adv = ce_7m & !repeated_pixel & (fine_x == (flip_screen ? 3'd0 : 3'd7));

	// =====================================================================
	// Fetch coordinate, LEAD tile columns ahead, wrapping into the next line
	// =====================================================================
	localparam logic [9:0] HPIXV = H_PIX[9:0];
	wire [9:0] pxa   = {1'b0, px} + 10'(8 * LEAD);
	wire       wrapf = (pxa >= HPIXV);
	wire [8:0] pxf   = wrapf ? 9'(pxa - HPIXV) : pxa[8:0];
	wire [8:0] linef = wrapf ? line_next : line;

	wire [8:0] fetch_x = flip_screen ? 9'd335-pxf : pxf;
	wire [8:0] fetch_y = flip_screen ? 9'd239-linef : linef;
	wire [8:0] mxf = fetch_x + xscroll + XOFFV;
	wire [8:0] myf = fetch_y + yscroll;

	// =====================================================================
	// Address register: one stable address per 8-pixel group
	// =====================================================================
	logic [5:0] col_l, row_l;
	logic [2:0] finey_l;

	always_ff @(posedge clk) begin
		if (reset) begin
			col_l   <= 6'd0;
			row_l   <= 6'd0;
			finey_l <= 3'd0;
		end else if (adv) begin
			col_l   <= mxf[8:3];
			row_l   <= myf[8:3];
			finey_l <= myf[2:0];
		end
	end

	// column-major: index = col * 64 + row
	wire [14:0] tile_idx = {3'b000, col_l, row_l};
	assign code_a = base_code + tile_idx;
	assign attr_a = base_attr + tile_idx;

	// =====================================================================
	// Code / attribute queue: LEAD-1 deep, head = the displayed column
	// =====================================================================
	localparam int DEPTH = (LEAD < 2) ? 1 : (LEAD - 1);
	logic [15:0] rcode [0:DEPTH-1];
	logic [15:0] rattr [0:DEPTH-1];
	integer i;

	// =====================================================================
	// The stamp-ROM pipe: `gp` is the fetch in flight, then two shift stages
	// =====================================================================
	logic [31:0] gp, g1, g0;
	logic        busy, arm;

	// batman_gfx_client holds `data_valid` from one fetch until it sees the
	// next `fetch` pulse, so `rom_valid` only answers this fetch from the cycle
	// after the pulse.  `arm` qualifies it; otherwise `busy` would clear early
	// and `rom_late` could never fire.
	wire rom_done = arm & rom_valid;

	always_ff @(posedge clk) begin
		rom_fetch <= 1'b0;
		rom_late  <= 1'b0;
		if (reset) begin
			for (i = 0; i < DEPTH; i = i + 1) begin
				rcode[i] <= 16'h0000;
				rattr[i] <= 16'h0000;
			end
			gp <= 32'd0; g1 <= 32'd0; g0 <= 32'd0;
			busy     <= 1'b0;
			arm      <= 1'b0;
			rom_addr <= 20'd0;
		end else begin
			if (!adv && !rom_fetch) arm <= 1'b1;
			if (rom_done) begin
				gp   <= rom_group;
				busy <= 1'b0;
			end
			if (adv) begin
				arm <= 1'b0;
				// (a) shift the column queue, newest word at the tail
				for (i = 0; i < DEPTH-1; i = i + 1) begin
					rcode[i] <= rcode[i+1];
					rattr[i] <= rattr[i+1];
				end
				rcode[DEPTH-1] <= code_q;
				rattr[DEPTH-1] <= attr_q;
				// (b) the stamp data in flight moves down with it; a
				//     `rom_valid` in this same cycle is forwarded, or a fetch
				//     finishing on the group's last clk would be lost.
				g0 <= g1;
				g1 <= rom_done ? rom_group : gp;
				// (c) the column just arrived starts its ROM fetch; `finey_l`
				//     still holds the row latched at the previous adv, which
				//     goes with this code word.
				rom_addr  <= {code_q[14:0], finey_l[2:0]};
				rom_fetch <= 1'b1;
				// A response arriving now is forwarded into g1 above, so the
				// previous group has met its deadline on this very edge.
				rom_late  <= busy && !rom_done;
				busy      <= 1'b1;
			end
		end
	end

	// =====================================================================
	// Pixel output latch, one pixel deep
	// =====================================================================
	wire       hflip = rcode[0][15];
	wire [2:0] bsel  = hflip ? fine_x : (3'd7 - fine_x);
	wire [3:0] raw_pen = { g0[{2'd3, bsel}], g0[{2'd2, bsel}],
	                       g0[{2'd1, bsel}], g0[{2'd0, bsel}] };

	logic [15:0] attr_w;
	always_ff @(posedge clk) begin
		if (reset) begin
			pen    <= 4'd0;
			attr_w <= 16'h0000;
		end else if (ce_7m && !repeated_pixel) begin
			pen    <= ROM_INVERT ? ~raw_pen : raw_pen;
			attr_w <= rattr[0];
		end
	end

	assign colour = ATTR_HIGH_BYTE ? attr_w[11:8]  : attr_w[3:0];
	assign pri    = ATTR_HIGH_BYTE ? attr_w[13:12] : attr_w[5:4];

	/* verilator lint_off UNUSEDSIGNAL */
	// Only the fine bits of the display coordinate are used; the coarse
	// column comes from the prefetch pipeline.
	wire _unused = &{1'b0, attr_w[15:14], attr_w[7:6], mx[8:3], mxf[2:0],
	                 pxa[9], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
