`timescale 1ns/1ps
//============================================================================
//  Batman motion-object engine: the MOB 137593-001 custom at 10F.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_mob.sv and skullxbo_mo_fetch.sv of the Skull &
//  Crossbones MiSTer core (GPL-3.0), which uses the same custom; see NOTICE.md.
//  The manual lacks the video sheets, so Batman's settings follow MAME's
//  atarimo configuration: 10-bit links, 4-word entries at MOBASE + 4 * link,
//  8 x 8 stamps, a 64-word SLIP table of 8-line bands, no vertical flip.
//
//  ThunderJaws adaptation: X offset zero, already-inverted planar bytes,
//  one coherent 64-bit descriptor read, and all 1024 links with visited-cycle
//  termination. ROM groups use plain {code,row}; rendering stays scanline based.
//============================================================================

module thunderjaws_mob #(
	// Target coordinate offset from thunderj.cpp / atarimo device defaults.
	parameter int MO_XOFF        = 0,
	// 1 SLIP word plus 1024 complete four-word descriptors.
	parameter int MO_WORD_BUDGET = 4097,
	// MAME's bitmap geometry, used by the coordinate folds.
	parameter int BITMAP_W       = 456,
	parameter int BITMAP_H       = 262,
	parameter int SLIP_SHIFT     = 3     // 8 scanlines per SLIP band
)(
	input  logic        clk,
	input  logic        reset,
	input  logic        flip_screen,

	// ---- one pulse per line, with the line to render ---------------------
	// (line N+1 is rendered during line N; the caller adds the one.)
	input  logic        line_start,
	input  logic  [8:0] vline,

	input  logic  [8:0] xscroll,
	input  logic  [8:0] yscroll,
	input  logic [14:0] base_mo,      // MOBASE, as a word index
	input  logic [14:0] base_slip,    // SLIPBASE, as a word index

	// ---- the scheduled video-RAM port: req held, ack is a one-clk pulse ---
	output logic [14:0] vram_a,
	output logic        vram_rd,
	input  logic        vram_ack,
	input  logic [63:0] vram_q,       // valid in the ack cycle

	// ---- the stamp ROM: one aligned plane group per (code, row) ----------
	output logic        rom_fetch,
	output logic [17:0] rom_addr,
	input  logic [31:0] rom_group,    // {plane3, plane2, plane1, plane0}
	input  logic        rom_valid,

	// ---- the line-buffer write side --------------------------------------
	output logic        lb_we,
	output logic  [9:0] lb_a,
	output logic [10:0] lb_d,         // {MPR2:0, MPAL3:0, MPX3:0} active high

	// ---- status, for debugging --------------------------------------------
	output logic        busy,
	output logic [12:0] words,        // video-RAM words this line has spent
	output logic        budget_hit,   // the walk was cut short
	output logic        line_over     // the walk was still running at line end
);

	typedef enum logic [3:0] {
		S_IDLE, S_SLIP, S_E3, S_FLUSH,
		S_TILE, S_ROMHOLD, S_ROMWAIT, S_PIX, S_E0, S_DONE
	} state_t;

	state_t st;

	logic  [5:0] band;
	logic [1023:0] visited;
	logic [9:0] next_link;
	logic  [9:0] link;
	logic [14:0] code;
	logic        hflip;
	logic  [3:0] width;               // 1..8 tiles across
	logic  [2:0] ty, row;
	logic  [3:0] j;                   // screen tile index, 0..width-1
	logic  [2:0] px;
	logic  [9:0] sx0;                 // this object's left edge, 10-bit wrap
	logic  [2:0] mpr;
	logic  [3:0] mcol;
	logic [31:0] rq;
	logic [63:0] prefetch_q;
	logic        prefetch_valid;
	logic        rom_stale;
	logic  [9:0] flush_link;
	wire last_tile = (st == S_PIX) && (px == 3'd7) && (j == width - 4'd1);
	wire [63:0] desc_q = (last_tile && prefetch_valid) ? prefetch_q : vram_q;
	wire [15:0] e3=desc_q[63:48],e2=desc_q[47:32],e1=desc_q[31:16];

	// ---------------------------------------------------------------------
	// Vertical match, in MAME's arithmetic so the wrap-around folds agree
	// ---------------------------------------------------------------------
	// ypos = (-Y - yscroll - 8*height) mod 512, folded below the bitmap height
	wire  [8:0] yfield   = e3[15:7];
	wire  [3:0] h_next   = {1'b0, e3[2:0]} + 4'd1;   // MAME masks 0x0007
	wire  [3:0] w_next   = {1'b0, e3[6:4]} + 4'd1;
	wire  [8:0] ypos_mod = 9'd0 - yfield - yscroll - {2'd0, h_next, 3'd0};
	wire signed [10:0] ypos_true =
		(ypos_mod >= BITMAP_H[8:0]) ? ($signed({2'b00, ypos_mod}) - 11'sd512)
		                            :  $signed({2'b00, ypos_mod});
	wire [8:0] source_line=flip_screen ? 9'd239-vline : vline;
	wire signed [10:0] dv = $signed({2'b00, source_line}) - ypos_true;
	wire signed [10:0] vext = $signed({4'd0, h_next, 3'd0});
	wire        vmatch = (dv >= 0) && (dv < vext);

	// the horizontal fold, on word 2
	wire  [8:0] xfield   = e2[15:7];
	wire  [8:0] xpos_mod = xfield + MO_XOFF[8:0] - xscroll;
	wire  [9:0] xpos_lb  = (xpos_mod >= BITMAP_W[8:0]) ? ({1'b0, xpos_mod} + 10'd512)
	                                                   :  {1'b0, xpos_mod};

	// the stamp for the tile now being fetched
	wire  [3:0] kcode = hflip ? (width - 4'd1 - j) : j;
	wire  [6:0] tyw   = {4'd0, ty} * {3'd0, width};   // <= 7 * 8 = 56
	wire [14:0] stamp = code + {8'd0, tyw} + {13'd0, kcode};

	// the pixel inside the stamp: bit `bsel` of each plane byte, MSB left
	wire  [2:0] bsel  = hflip ? px : (3'd7 - px);
	wire  [3:0] pen_n = {rq[{2'd3, bsel}], rq[{2'd2, bsel}],
	                     rq[{2'd1, bsel}], rq[{2'd0, bsel}]};
	wire  [2:0] first_bsel = hflip ? 3'd0 : 3'd7;
	wire  [3:0] first_pen = {rom_group[{2'd3, first_bsel}], rom_group[{2'd2, first_bsel}],
	                        rom_group[{2'd1, first_bsel}], rom_group[{2'd0, first_bsel}]};
	wire [9:0] first_pixel_x = sx0 + {3'd0,j,3'd0};

	wire over_budget = (words >= MO_WORD_BUDGET[12:0]);

	// band = ((y + yscroll) mod 512) >> 3; a 9-bit wire so the sum wraps at 512.
	wire  [8:0] bsum = source_line + yscroll;
	wire [9:0] pixel_x=sx0 + {3'd0,j,3'd0} + {7'd0,px};
	// Keep tiles crossing the 10-bit wrap: their trailing pixels can appear at
	// the left edge. Other tiles entirely outside 0..335 cannot write the line.
	wire [9:0] tile_x=sx0 + {3'd0,j,3'd0};
	wire tile_visible=(tile_x < 10'd336) || (tile_x >= 10'd1017);
	wire first_tile_visible=(xpos_lb < 10'd336) || (xpos_lb >= 10'd1017);
	wire prefetch_slot=((st == S_ROMWAIT) || (st == S_PIX)) &&
		(width == 4'd1) && tile_visible && !visited[next_link] && !over_budget;
	wire prefetch_request=prefetch_slot && !prefetch_valid && !vram_ack;
	wire prefetch_ack=prefetch_slot && !prefetch_valid && vram_ack;
	wire consume_prefetch=last_tile && (prefetch_valid || prefetch_ack);
	wire [3:0] desc_kcode=e1[15] ? (w_next - 4'd1) : 4'd0;
	wire [6:0] desc_tyw={4'd0,dv[5:3]} * {3'd0,w_next};
	wire [14:0] desc_stamp=e1[14:0] + {8'd0,desc_tyw} + {11'd0,desc_kcode};
	wire direct_rom_fetch=
		((st == S_E3) && vram_ack && !over_budget && vmatch &&
		 (w_next == 4'd1) && first_tile_visible) ||
		((st == S_PIX) && consume_prefetch && vmatch &&
		 (w_next == 4'd1) && first_tile_visible);

	// Prepared sprite plane groups retain the target byte-per-row layout.
	assign rom_addr = direct_rom_fetch ? {desc_stamp,dv[2:0]} : {stamp, row};

	always_comb begin
		vram_a  = 15'd0;
		vram_rd = 1'b0;
		rom_fetch = !reset && !line_start &&
			(((st == S_TILE) && (j < width) && tile_visible) || direct_rom_fetch);
		case (st)
			S_SLIP: begin vram_a = base_slip + {9'd0, band};      vram_rd = 1'b1; end
			S_E3:   begin vram_a = base_mo + {3'd0, link, 2'b11}; vram_rd = 1'b1; end
			S_FLUSH:begin vram_a = base_mo + {3'd0, flush_link, 2'b11}; vram_rd = 1'b1; end
			default:  ;
		endcase
		if (!reset && !line_start && prefetch_request) begin
			vram_a = base_mo + {3'd0, next_link, 2'b11};
			vram_rd = 1'b1;
		end
	end

	assign busy  = (st != S_IDLE) && (st != S_DONE);

	always_ff @(posedge clk) begin
		if (reset) begin
			st         <= S_IDLE;
			visited <= '0;
			prefetch_valid <= 1'b0;
			rom_stale <= 1'b0;
			lb_we      <= 1'b0;
			words      <= 13'd0;
			budget_hit <= 1'b0;
			line_over  <= 1'b0;
		end else begin
			lb_we     <= 1'b0;

			if (line_start) begin
				// The SLIP band scrolls with the objects.
				band       <= bsum[8:SLIP_SHIFT];
				words      <= 13'd0;
				budget_hit <= 1'b0;
				prefetch_valid <= 1'b0;
				rom_stale <= 1'b0;
				if (busy) line_over <= 1'b1;
				visited <= '0;
				if (st == S_FLUSH) st <= S_FLUSH;
				else if (prefetch_request && !vram_ack) begin
					flush_link <= next_link;
					st <= S_FLUSH;
				end else if(vline<240)st<=S_SLIP;else st<=S_DONE;
			end else begin
				if (direct_rom_fetch) rom_stale <= rom_valid;
				if (prefetch_ack) begin
					words <= words + 13'd4;
					visited[next_link] <= 1'b1;
					if (!consume_prefetch) begin
						prefetch_q <= vram_q;
						prefetch_valid <= 1'b1;
					end else prefetch_valid <= 1'b0;
				end
				case (st)
					// ---- the head link ---------------------------------
					S_SLIP: if (vram_ack) begin
						words <= words + 13'd1;
						link  <= vram_q[9:0];
						st    <= S_E3;
					end

                    // One accepted bank-3 row returns all four descriptor words.
                    // CPU byte writes and this read are serialized by the RAM port.
                    S_E3: if (over_budget) begin budget_hit<=1;st<=S_DONE;end
                    else if(vram_ack)begin
                        words<=words+13'd4;visited[link]<=1;next_link<=vram_q[9:0];
                        width<=w_next;ty<=dv[5:3];row<=dv[2:0];
                        code<=e1[14:0];hflip<=e1[15];sx0<=xpos_lb;
                        mpr<=e2[6:4];mcol<=e2[3:0];j<=0;
						if(vmatch)begin
							if ((w_next == 4'd1) && first_tile_visible) begin
								px <= 3'd0;
								st <= S_ROMWAIT;
							end else st<=S_TILE;
						end
                        else if(vram_q[9:0]==link || visited[vram_q[9:0]])st<=S_DONE;
                        else begin link<=vram_q[9:0];st<=S_E3;end
                    end

					S_FLUSH: if (vram_ack) begin
						if (vline < 240) st <= S_SLIP;
						else st <= S_DONE;
					end

					// ---- the tiles -------------------------------------
					S_TILE: if(j<width)begin
						if(tile_visible)begin
							st        <= S_ROMHOLD;
						end else j<=j+4'd1;
					end else st<=S_E0;
					// batman_gfx_client holds `data_valid` from the previous
					// fetch until it sees this `fetch` pulse; wait one cycle so
					// the previous stamp's data is not taken.
					S_ROMHOLD: st <= S_ROMWAIT;
					S_ROMWAIT: begin
						if (rom_stale) begin
							if (!rom_valid) rom_stale <= 1'b0;
						end else if (rom_valid) begin
							rq    <= rom_group;
							px    <= 3'd1;
							lb_we <= first_pixel_x < 10'd336;
							lb_a  <= flip_screen ? 10'd335-first_pixel_x : first_pixel_x;
							lb_d  <= {mpr, mcol, first_pen};
							st    <= S_PIX;
						end
					end
					S_PIX:  begin
						lb_we <= pixel_x < 10'd336;
						lb_a  <= flip_screen ? 10'd335-pixel_x : pixel_x;
						lb_d  <= {mpr, mcol, pen_n};
						px    <= px + 3'd1;
						if (px == 3'd7) begin
							if (j < width - 4'd1) begin
								j  <= j + 4'd1;
								st <= S_TILE;
							end else if (consume_prefetch) begin
								link <= next_link;
								next_link <= desc_q[9:0];
								width <= w_next;ty <= dv[5:3];row <= dv[2:0];
								code <= e1[14:0];hflip <= e1[15];sx0 <= xpos_lb;
								mpr <= e2[6:4];mcol <= e2[3:0];j <= 0;px <= 0;
								if (prefetch_ack) begin
									words <= words + 13'd4;
									visited[next_link] <= 1'b1;
								end
								prefetch_valid <= 1'b0;
								if (vmatch) begin
									if ((w_next == 4'd1) && first_tile_visible) st <= S_ROMWAIT;
									else st <= S_TILE;
								end else if (desc_q[9:0] == next_link || visited[desc_q[9:0]]) st <= S_DONE;
								else begin link <= desc_q[9:0]; st <= S_E3; end
							end else if (visited[next_link]) st <= S_DONE;
							else begin link <= next_link; st <= S_E3; end
						end
					end

                    // Every previously visited link terminates a list, including
                    // multi-object cycles; no donor short list quota is retained.
                    S_E0: if(visited[next_link])st<=S_DONE;
                    else begin link<=next_link;st<=S_E3;end

					S_IDLE, S_DONE: ;        // parked until the next line
					default: st <= S_DONE;
				endcase
			end
		end
	end

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, ypos_true[10], dv[10:6], bsum[2:0], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
