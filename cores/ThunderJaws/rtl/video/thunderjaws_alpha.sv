// ThunderJaws adaptation of Batman commit34783858f6e1511e299ef159d6316544934f8fb5.
// Donor source remains byte-preserved; target changes: docs/VIDEO_PORTING.md.
`timescale 1ns/1ps
//============================================================================
//  Batman alphanumerics layer: 64 x 30 characters of 8 x 8 pixels, 2 bpp,
//  row-major in video RAM at ALBASE (0x2F8000), never scrolled.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_alpha.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.
//
//  Cell word (as MAME decodes it; the video sheets are not in the manual):
//      bits  8-0  character code
//      bit   9    bank enable: 1 -> code + ALBK * 0x200
//      bits13-10 colour low4; bit14 supplies color bit5 (bit4=0)
//      bit  15    opaque (ALBG): pen 0 is drawn too
//  ALBK2:0 is LS273 output latch 1S bits 14:12 (from the schematic).  Three
//  bank bits cover the whole 4096-character (64 KB) ROM.
//
//  The character ROM is NOT bit-inverted (unlike the other graphics ROMs) and
//  lives in BRAM.  Each character row is one 16-bit word, code * 8 + row; in
//  each byte the high nibble holds pen bit 1 and the low nibble pen bit 0 of
//  four pixels.  The layer fetches LEAD cells ahead of the beam and holds one
//  video-RAM address per 8-pixel group, as the shared video-RAM slot requires.
//  Columns 42-63 hold data for the VAD's DMA channel and are not drawn.
//============================================================================

module thunderjaws_alpha #(
	parameter int LEAD  = 4,      // character cells of prefetch
	parameter int H_PIX = 456     // pixels per line (H_TOTAL / 2)
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        flip_screen,
	input  logic        ce_7m,         // one pulse per pixel, at its end

	// ---- raster ------------------------------------------------------------
	input  logic  [8:0] px,            // display pixel 0..H_PIX-1
	input  logic  [8:0] line,
	input  logic  [8:0] line_next,     // the following line, wrapped at VLAST

	// ---- configuration -----------------------------------------------------
	input  logic  [2:0] albk,          // LS273 1S bits 14:12
	input  logic [14:0] base_alpha,    // word index of ALBASE, from VAD reg 09

	// ---- the scheduled video-RAM port (batman_vram.sv) ---------------------
	output logic [14:0] vram_a,        // held for a whole 8-pixel group
	input  logic [15:0] vram_q,

	// ---- the character ROM (64 KB BRAM, 16-bit, not inverted) -------------
	output logic [14:0] rom_a,         // word index = code * 8 + row
	input  logic [15:0] rom_q,         // {even byte, odd byte} = {x<4, x>=4}

	// ---- the layer's pixel, one pixel after `px` ---------------------------
	output logic  [1:0] apix,          // APIX1:0
	output logic  [5:0] alc,           // ALC3:0
	output logic        albg,          // the opaque flag
    output logic vram_fetch           // new address is stable with this pulse
);

	wire [8:0] source_x=flip_screen ? 9'd335-px : px;
	wire [2:0] fx = source_x[2:0];
	wire       adv = ce_7m & (fx == (flip_screen ? 3'd0 : 3'd7));
    always_ff @(posedge clk) vram_fetch <= !reset && adv;

	// =====================================================================
	// Fetch coordinate, LEAD cells ahead, wrapping into the next line
	// =====================================================================
	localparam logic [9:0] HPIXV = H_PIX[9:0];
	wire [9:0] pxa   = {1'b0, px} + 10'(8 * LEAD);
	wire       wrapf = (pxa >= HPIXV);
	wire [8:0] pxf   = wrapf ? 9'(pxa - HPIXV) : pxa[8:0];
	wire [8:0] linef = wrapf ? line_next : line;
	wire [8:0] fetch_x=flip_screen ? 9'd335-pxf : pxf;
	wire [8:0] fetch_y=flip_screen ? 9'd239-linef : linef;

	logic [5:0] col_l;
	logic [4:0] crow_l;
	logic [2:0] fy_l;

	always_ff @(posedge clk) begin
		if (reset) begin
			col_l  <= 6'd0;
			crow_l <= 5'd0;
			fy_l   <= 3'd0;
		end else if (adv) begin
			col_l  <= fetch_x[8:3];
			crow_l <= fetch_y[7:3];
			fy_l   <= fetch_y[2:0];
		end
	end

	// row-major: index = crow * 64 + col
	assign vram_a = base_alpha + {4'b0000, crow_l, col_l};

	// =====================================================================
	// Cell-word queue and ROM pipe (same shape as batman_pf.sv)
	// =====================================================================
	localparam int DEPTH = (LEAD < 2) ? 1 : (LEAD - 1);
	logic [15:0] rw [0:DEPTH-1];
	logic [15:0] gp, g1, g0;
	integer i;

	always_ff @(posedge clk) begin
		if (reset) begin
			for (i = 0; i < DEPTH; i = i + 1) rw[i] <= 16'h0000;
			gp    <= 16'h0000; g1 <= 16'h0000; g0 <= 16'h0000;
			rom_a <= 15'd0;
		end else begin
			gp <= rom_q;                       // the BRAM answers every clk
			if (adv) begin
				for (i = 0; i < DEPTH-1; i = i + 1) rw[i] <= rw[i+1];
				rw[DEPTH-1] <= vram_q;
				g0 <= g1;
				g1 <= gp;
				// `fy_l` still holds the row latched at the previous adv, which
				// is the row that goes with `vram_q`.
				rom_a <= {(vram_q[9] ? albk : 3'b000), vram_q[8:0], fy_l};
			end
		end
	end

	// =====================================================================
	// Pixel output latch
	// =====================================================================
	wire [7:0] b    = fx[2] ? g0[7:0] : g0[15:8];
	wire [1:0] fsel = fx[1:0];
	wire [2:0] hi   = 3'd7 - {1'b0, fsel};
	wire [2:0] lo   = 3'd3 - {1'b0, fsel};

	always_ff @(posedge clk) begin
		if (reset) begin
			apix <= 2'd0;
			alc  <= 6'd0;
			albg <= 1'b0;
		end else if (ce_7m) begin
			apix <= {b[hi], b[lo]};
			alc  <= {rw[0][14],1'b0,rw[0][13:10]};
			albg <= rw[0][15];
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	// Cells are 8 pixels wide and there are 30 rows, so the fine fetch bits and
	// line bit 8 never reach an address.
	wire _unused = &{1'b0, line[8], pxa[9], pxf[2:0], linef[8], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
