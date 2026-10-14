//============================================================================
// Ikki video — MAME-aligned timing, BG, 16×32 sprites, PROM RGB, punch-through
// Line buffers are M10K BRAMs; sprite pixels are drawn one-per-cycle (fits FPGA).
//============================================================================
module ikki_video
(
	input         clk,
	input         reset,
	input         ce_pix,

	input         flipscreen,
	input   [7:0] scroll_y,
	input   [7:0] scroll_x,

	output [10:0] vram_addr,
	input   [7:0] vram_q,

	output [10:0] spr_addr,
	input   [7:0] spr_q,
	// Pulses whenever the sub CPU writes sprite RAM.  The snapshot engine uses
	// it to detect that a copy pass raced the CPU and must be retried; see the
	// collision handling at the snapshot state machine.
	input         spr_wr_stb,

	output [15:0] tile_addr,
	input   [7:0] tile_q,
	output [15:0] sprite_addr,
	input   [7:0] sprite_q,
	output  [9:0] lut_addr,
	input   [7:0] lut_q,
	output  [7:0] pal_addr,
	input   [7:0] pal_r_q,
	input   [7:0] pal_g_q,
	input   [7:0] pal_b_q,
	output  [8:0] attr_addr,
	input   [7:0] attr_q,
	output  [5:0] spr_trans_addr,
	input   [7:0] spr_trans_q,

	output        hs,
	output        vs,
	output        hblank,
	output        vblank,
	output  [3:0] r,
	output  [3:0] g,
	output  [3:0] b,

	output  [8:0] hcnt_o,
	output  [8:0] vcnt_o,
	output        irq_vblank,
	output        irq_mid,

	// Sticky flag: the sprite line pass ran out of time on at least one line.
	// Diagnostic only — consumed by the testbenches.
	output reg    spr_overflow
);

localparam H_TOTAL  = 9'd320;
localparam V_TOTAL  = 9'd262;
localparam HB_END   = 9'd8;
localparam HB_START = 9'd248;
localparam VB_END   = 9'd16;
localparam VB_START = 9'd240;

reg [8:0] hcnt, vcnt;
always @(posedge clk) begin
	if (reset) begin
		hcnt <= 0;
		vcnt <= 0;
	end else if (ce_pix) begin
		if (hcnt == H_TOTAL - 1'd1) begin
			hcnt <= 0;
			vcnt <= (vcnt == V_TOTAL - 1'd1) ? 9'd0 : (vcnt + 1'd1);
		end else
			hcnt <= hcnt + 1'd1;
	end
end

assign hcnt_o = hcnt;
assign vcnt_o = vcnt;

// Raw raster flags, in the same time base as hcnt/vcnt.
wire hblank_raw = (hcnt < HB_END) || (hcnt >= HB_START);
wire vblank_raw = (vcnt < VB_END) || (vcnt >= VB_START);
wire hs_raw     = (hcnt >= 9'd260) && (hcnt < 9'd284);
wire vs_raw     = (vcnt >= 9'd245) && (vcnt < 9'd249);

// The renderer does not emit a pixel in the same slot it is addressed: the
// line-buffer read is registered, the palette walk occupies the gap between
// pixel enables, and the RGB output is registered again.  Measured with
// verif/sim_video_ref.cpp (+LATENCY sweep, sharp minimum), visible pixel 0
// leaves the pipeline at hcnt 17 rather than hcnt 8.
//
// Delaying the blanking and sync outputs by that many pixel enables realigns
// them with the pixels they describe.  Left undelayed, the picture was shifted
// right by RGB_DELAY and the same number of columns fell off the right edge.
localparam RGB_DELAY = 9;

reg [RGB_DELAY-1:0] hb_sr, vb_sr, hs_sr, vs_sr;
always @(posedge clk) begin
	if (reset) begin
		hb_sr <= {RGB_DELAY{1'b1}};
		vb_sr <= {RGB_DELAY{1'b1}};
		hs_sr <= 0;
		vs_sr <= 0;
	end else if (ce_pix) begin
		hb_sr <= {hb_sr[RGB_DELAY-2:0], hblank_raw};
		vb_sr <= {vb_sr[RGB_DELAY-2:0], vblank_raw};
		hs_sr <= {hs_sr[RGB_DELAY-2:0], hs_raw};
		vs_sr <= {vs_sr[RGB_DELAY-2:0], vs_raw};
	end
end

assign hblank = hb_sr[RGB_DELAY-1];
assign vblank = vb_sr[RGB_DELAY-1];
assign hs     = hs_sr[RGB_DELAY-1];
assign vs     = vs_sr[RGB_DELAY-1];

reg [8:0] vcnt_d;
reg irq_vblank_r, irq_mid_r;
always @(posedge clk) if (ce_pix) begin
	vcnt_d <= vcnt;
	irq_vblank_r <= (vcnt == VB_START) && (vcnt_d != VB_START);
	irq_mid_r    <= (vcnt == 9'd120) && (vcnt_d != 9'd120);
end
assign irq_vblank = irq_vblank_r;
assign irq_mid    = irq_mid_r;

// Dual line buffers (M10K) — render next line while displaying current
reg       bufsel;
reg       bg_wsel;
reg       sp_wsel;
reg [31:0] lb_mask0, lb_mask1;

wire       bg_we;
wire [7:0] bg_waddr;
wire [9:0] bg_wdata;
wire       spr_we;
wire [7:0] spr_waddr;
wire [9:0] spr_wdata;

wire [9:0] bg0_q, bg1_q, spr0_q, spr1_q;

wire [8:0] hcnt_next = (hcnt == H_TOTAL - 1'd1) ? 9'd0 : (hcnt + 1'd1);
wire [7:0] fetch_x   = hcnt_next[7:0] - HB_END[7:0];

ikki_linebuf u_bg0  (.clk(clk), .we(bg_we  & ~bg_wsel), .waddr(bg_waddr),  .wdata(bg_wdata),  .raddr(fetch_x), .q(bg0_q));
ikki_linebuf u_bg1  (.clk(clk), .we(bg_we  &  bg_wsel), .waddr(bg_waddr),  .wdata(bg_wdata),  .raddr(fetch_x), .q(bg1_q));
ikki_linebuf u_spr0 (.clk(clk), .we(spr_we & ~sp_wsel), .waddr(spr_waddr), .wdata(spr_wdata), .raddr(fetch_x), .q(spr0_q));
ikki_linebuf u_spr1 (.clk(clk), .we(spr_we &  sp_wsel), .waddr(spr_waddr), .wdata(spr_wdata), .raddr(fetch_x), .q(spr1_q));

wire [7:0] scroll_y_inv = ~scroll_y;
// MAME places each tile at y = (tile_y + ~scroll_y) & 0xff, and under flip at
// 248 - that.  Rendering runs the other way (screen line -> source tile row),
// so both cases subtract the destination offset:
//
//   unflipped   v = (L - ~scroll_y) & 0xff
//   flipped     v = ((255 - L) - ~scroll_y) & 0xff
//
// with tile row = v[7:3] and row-within-tile = v[2:0].  The flipped form used
// to add ~scroll_y, which only agrees with MAME when ~scroll_y is 0.
wire [7:0] bg_line_flip          = 8'd255 - bg_line[7:0];
wire [7:0] bg_line_scrolled      = bg_line[7:0] - scroll_y_inv;
wire [7:0] bg_line_flip_scrolled = bg_line_flip - scroll_y_inv;

reg [10:0] vram_a, spr_a;
reg [15:0] tile_a, sprite_a;
reg [8:0]  attr_a;
assign vram_addr   = vram_a;
assign spr_addr    = spr_a;
assign tile_addr   = tile_a;
assign sprite_addr = sprite_a;
assign attr_addr   = attr_a;

// =========================================================================
// BG renderer
// =========================================================================
localparam BG_IDLE            = 4'd0;
localparam BG_ATTR            = 4'd1;
localparam BG_ATTR_WAIT       = 4'd2;
localparam BG_COL             = 4'd3;
localparam BG_CODE            = 4'd4;
localparam BG_VRAM_COLOR_WAIT = 4'd5;
localparam BG_VRAM_COLOR      = 4'd6;
localparam BG_VRAM_CODE_WAIT  = 4'd7;
localparam BG_VRAM_CODE       = 4'd8;
localparam BG_TILE0_WAIT      = 4'd9;
localparam BG_TILE0           = 4'd10;
localparam BG_TILE1_WAIT      = 4'd11;
localparam BG_TILE1           = 4'd12;
localparam BG_TILE2_WAIT      = 4'd13;
localparam BG_TILE2           = 4'd14;
localparam BG_EMIT            = 4'd15;

reg [3:0] bg_st;
reg [4:0] bg_sx;
reg [4:0] bg_sy;
reg [7:0] bg_attr, bg_color, bg_code, bg_ty;
// Destination X of the column, signed.  MAME computes
//   x = sx*8 - scroll_x;  if (x < 0) x += 8*22;
// which spans -255..248, so it cannot be represented in the 8 bits this used
// to use.  The old code recovered the sign with `bg_dx > 200`, which is only
// correct while scroll_x - sx*8 <= 55.
reg signed [10:0] bg_dx;
wire signed [10:0] bg_col_x   = $signed({3'b0, bg_sx, 3'b000});
wire signed [10:0] bg_scr_raw = bg_col_x - $signed({3'b0, scroll_x});
wire signed [10:0] bg_scr_x   = (bg_scr_raw < 0) ? (bg_scr_raw + 11'sd176) : bg_scr_raw;
// Screen column this tilemap column lands on when it is not scrolled.
wire signed [10:0] bg_fix_x   = flipscreen ? (11'sd248 - bg_col_x) : bg_col_x;
wire         [4:0] bg_mask_col = bg_fix_x[7:3];
reg [7:0] p0, p1, p2;
reg [3:0] bg_bit;
reg [8:0] bg_line;
reg       bg_busy;

wire [15:0] tile_bank   = {8'b0, (bg_color & 8'hE0)} << 3;
wire [15:0] tile_code16 = {8'b0, bg_code} + tile_bank;
wire [15:0] tile_base   = tile_code16 << 3;

reg       bg_we_r;
reg [7:0] bg_waddr_r;
reg [9:0] bg_wdata_r;
assign bg_we    = bg_we_r;
assign bg_waddr = bg_waddr_r;
assign bg_wdata = bg_wdata_r;

always @(posedge clk) begin
	bg_we_r <= 0;
	if (reset) begin
		bg_st   <= BG_IDLE;
		bg_busy <= 0;
		bufsel  <= 0;
		bg_wsel <= 0;
	end else begin
		if (ce_pix && hcnt == 9'd0) begin
			bufsel  <= ~bufsel;
			bg_wsel <= bufsel;
			bg_line <= (vcnt == V_TOTAL - 1'd1) ? 9'd0 : (vcnt + 1'd1);
			bg_sx   <= 0;
			bg_st   <= BG_ATTR;
			bg_busy <= 1;
		end else if (bg_busy) begin
			case (bg_st)
			BG_ATTR: begin
				attr_a <= {4'b0, bg_sx};
				bg_st  <= BG_ATTR_WAIT;
			end
			BG_ATTR_WAIT: begin
				bg_st  <= BG_COL;
			end
			BG_COL: begin
				bg_attr <= attr_q;
				// MAME's second pass redraws attribute 0x00 / 0x0D columns over
				// the sprites.  Here that is a per-column flag consulted while
				// compositing, so it has to be indexed by the column's position
				// on screen, not by its tilemap index: under flip MAME maps
				// column 22 to x = 72, i.e. screen column 9.  Neither of these
				// attributes ever appears on a scrolling column, so the
				// unscrolled position is the right one.
				if (bg_wsel) lb_mask1[bg_mask_col] <= (attr_q == 8'h00) || (attr_q == 8'h0D);
				else         lb_mask0[bg_mask_col] <= (attr_q == 8'h00) || (attr_q == 8'h0D);

				if (attr_q == 8'h02) begin
					if (flipscreen) begin
						bg_sy <= bg_line_flip_scrolled[7:3];
						bg_ty <= {5'b0, bg_line_flip_scrolled[2:0]};
					end else begin
						bg_sy <= bg_line_scrolled[7:3];
						bg_ty <= {5'b0, bg_line_scrolled[2:0]};
					end
					bg_dx <= bg_scr_x;
				end else begin
					if (flipscreen) begin
						bg_sy <= bg_line_flip[7:3];
						bg_ty <= {5'b0, bg_line_flip[2:0]};
					end else begin
						bg_sy <= bg_line[7:3];
						bg_ty <= {5'b0, bg_line[2:0]};
					end
					bg_dx <= bg_col_x;
				end
				bg_st <= BG_CODE;
			end
			BG_CODE: begin
				vram_a <= {bg_sx, bg_sy, 1'b0};
				bg_st  <= BG_VRAM_COLOR_WAIT;
			end
			BG_VRAM_COLOR_WAIT: begin
				bg_st <= BG_VRAM_COLOR;
			end
			BG_VRAM_COLOR: begin
				bg_color <= vram_q;
				vram_a   <= {bg_sx, bg_sy, 1'b1};
				bg_st    <= BG_VRAM_CODE_WAIT;
			end
			BG_VRAM_CODE_WAIT: begin
				bg_st <= BG_VRAM_CODE;
			end
			BG_VRAM_CODE: begin
				bg_code <= vram_q;
					tile_a  <= (({8'b0, vram_q} + ({8'b0, (bg_color & 8'hE0)} << 3)) << 3) + {8'b0, bg_ty};
				bg_st   <= BG_TILE0_WAIT;
			end
			BG_TILE0_WAIT: begin
				bg_st <= BG_TILE0;
			end
			BG_TILE0: begin
				p0     <= tile_q;
				tile_a <= 16'h4000 + tile_base + {8'b0, bg_ty};
				bg_st  <= BG_TILE1_WAIT;
			end
			BG_TILE1_WAIT: begin
				bg_st <= BG_TILE1;
			end
			BG_TILE1: begin
				p1     <= tile_q;
				tile_a <= 16'h8000 + tile_base + {8'b0, bg_ty};
				bg_st  <= BG_TILE2_WAIT;
			end
			BG_TILE2_WAIT: begin
				bg_st <= BG_TILE2;
			end
			BG_TILE2: begin
				p2     <= tile_q;
				bg_st  <= BG_EMIT;
				bg_bit <= 0;
			end
			BG_EMIT: begin
				begin : emit
					reg [2:0] bi;
					reg [2:0] bix;
					reg [2:0] pix;
					reg [5:0] col;
					reg signed [10:0] x0;
					reg signed [10:0] xg;
					bi  = bg_bit[2:0];
					// MAME draws the flipped tile at the same top-left corner
					// and mirrors the source, so the destination advances with
					// bi in both orientations; only the source bit reverses.
					bix = flipscreen ? (3'd7 - bi) : bi;
					pix = {p0[bix], p1[bix], p2[bix]};
					col = 6'((bg_color & 8'h1F) | ((bg_color & 8'h80) >> 2));
					x0  = flipscreen ? (11'sd248 - bg_dx) : bg_dx;
					xg  = x0 + $signed({8'b0, bi});
					// The line buffer is indexed in MAME's raster space, which
					// starts 8 pixels left of the visible area: the compositor
					// reads entries HB_END..HB_START-1, so a column at raster
					// 240..247 is the right-most *visible* one.  Clipping at 240
					// discarded it, which is why the far-right column showed
					// stale data.
					if (xg >= 11'sd0 && xg < 11'sd248) begin
						bg_we_r    <= 1'b1;
						bg_waddr_r <= xg[7:0];
						bg_wdata_r <= 10'h200 + {1'b0, col, pix};
					end
				end
				if (bg_bit == 4'd7) begin
					// All 32 columns are walked.  Columns 30 and 31 sit off a
					// 240-wide screen unflipped, but under flip MAME maps them
					// to x = 8 and x = 0.  The clip above discards whichever
					// end is off-screen.
					if (bg_sx == 5'd31) begin
						bg_busy <= 0;
						bg_st   <= BG_IDLE;
					end else begin
						bg_sx <= bg_sx + 1'd1;
						bg_st <= BG_ATTR;
					end
				end else
					bg_bit <= bg_bit + 1'd1;
			end
			default: bg_st <= BG_IDLE;
			endcase
		end
	end
end

// =========================================================================
// Sprite line pass — full 16×32 (MAME spritelayout), 1 pixel / cycle.
// The sprite RAM has 512 four-byte entries.  Cache the complete attribute
// table during the top border so the visible-line pass cannot restart midway
// through a line and leave stale/floating sprite rows in the line buffer.
// =========================================================================
localparam SP_IDLE       = 4'd0;
localparam SP_CLR        = 4'd1;
localparam SP_SCAN       = 4'd2;
localparam SP_FETCH      = 4'd3;
localparam SP_DRAW       = 4'd4;
localparam SP_PRIME      = 4'd5;
localparam SP_PRIME2     = 4'd6;

localparam SPC_IDLE      = 2'd0;
localparam SPC_ADDR      = 2'd1;
localparam SPC_WAIT      = 2'd2;
localparam SPC_CAPTURE   = 2'd3;

reg [3:0] sp_st;
reg [8:0] sp_i;
reg [7:0] sp_clr;
reg [7:0] sp_y, sp_codeb, sp_at, sp_x;
reg [7:0] sp_row;
reg [7:0] s0l, s1l, s2l, s0r, s1r, s2r;
reg [3:0] sp_phase;
reg [3:0] sp_px;
reg       sp_busy;
reg [7:0] sp_code_full;
reg signed [9:0] sp_xs, sp_ys;
reg [15:0] sp_row_off;
// Transparency mask for the sprite currently being drawn (bit p set = pen p
// has colour-table entry 0).  Fetched once per sprite; the colour is constant
// across the whole character.
reg [5:0] sp_trans_a;
reg [7:0] sp_trans_mask;
assign spr_trans_addr = sp_trans_a;

reg [1:0] spc_st;
reg [8:0] spc_i;
reg [1:0] spc_byte;
reg       spc_busy;
reg       spc_valid;

// Snapshot of the sprite attribute table, compacted.
//
// This used to be four 512x8 register arrays plus a 512x9 index list, all read
// combinationally at a computed index.  Quartus cannot infer RAM from that, so
// it built ~16k flip-flops and 512-way multiplexers: ikki_video alone came to
// 9211 ALMs and 15896 registers, 46% of the design (docs/AUDIT.md D1).
//
// Records that decode to the known-blank character 0 are dropped as they are
// captured and the survivors are stored contiguously, so the line pass walks
// 0..spc_count-1 with no indirection and the index list disappears too.
//
// Word layout: {x, attr, code, y}.
localparam SPC_W = 32;
(* ramstyle = "no_rw_check, M10K" *)
reg [SPC_W-1:0] spc_mem [0:511] /* verilator public_flat_rw */;

reg  [8:0]  spc_rd_a;
reg  [SPC_W-1:0] spc_rd_q;
reg  [9:0]  spc_count;

// Collision tracking for the copy pass.  spc_dirty is set by any sub-CPU
// sprite-RAM write that lands while a pass is copying; a dirty pass mixes
// records from two frames and is retried rather than published.
// spc_pub_dirty_cnt counts the passes that were published dirty anyway
// because the retry deadline was reached -- in a healthy run it stays 0.
reg         spc_dirty;
reg [15:0]  spc_pub_dirty_cnt /* verilator public_flat_rw */;
reg [15:0]  spc_retry_cnt     /* verilator public_flat_rw */;

// Bytes 0..2 of the record being captured; byte 3 arrives with the write.
reg  [7:0]  spc_b0, spc_b1, spc_b2;

always @(posedge clk) spc_rd_q <= spc_mem[spc_rd_a];

reg       spr_we_r;
reg [7:0] spr_waddr_r;
reg [9:0] spr_wdata_r;
assign spr_we    = spr_we_r;
assign spr_waddr = spr_waddr_r;
assign spr_wdata = spr_wdata_r;

always @(posedge clk) begin
	spr_we_r <= 0;
	if (reset) begin
		sp_st      <= SP_IDLE;
		sp_busy    <= 0;
		sp_wsel    <= 0;
		spc_st     <= SPC_IDLE;
		spc_i      <= 0;
		spc_byte   <= 0;
		spc_busy   <= 0;
		spc_valid  <= 0;
		spc_count  <= 0;
		spc_rd_a   <= 0;
		spc_dirty  <= 0;
		spc_pub_dirty_cnt <= 0;
		spc_retry_cnt     <= 0;
		spr_overflow <= 0;
	end else begin

		// Four registered reads per sprite attribute record: 512 * 4 * 3 = 6144
		// cycles, which is 2.4 lines at 2560 cycles per line.
		//
		// The copy has to happen while the sub Z80 is not rewriting the table,
		// or it tears -- some entries from this frame, some from the last --
		// and sprites flicker for a frame.  A fixed start line cannot
		// guarantee that: line 250 was chosen when the sub was interrupted at
		// lines 0 and 131, then the interrupt model moved to lines 240/120 and
		// the sub's post-vblank sprite work landed exactly on it.  Measured on
		// 2026-07-29: sub writes during the copy on every other attract frame,
		// all at line 250, and firing shifts the player entry's rewrite into
		// the window -- the reported fire-mash player flicker.
		//
		// So the copy defends itself instead of trusting a quiet window: any
		// sub write during a pass marks it dirty, and a dirty pass is retried
		// from scratch rather than published.  Retries fit easily -- the pass
		// takes 2.4 lines and the first line fetch needs the table at vcnt 15,
		// so attempts starting anywhere in vcnt >= 250 or vcnt <= 12 complete
		// in time.  If the CPU wrote continuously through every attempt the
		// last pass is published dirty at the deadline (spc_pub_dirty_cnt
		// counts this; it is the pre-fix behaviour, and a healthy run shows 0).
		if (ce_pix && hcnt == 9'd0 && vcnt == 9'd250 && !spc_busy) begin
			spc_i     <= 0;
			spc_byte  <= 0;
			spc_busy  <= 1;
			spc_valid <= 0;
			spc_count <= 0;
			spc_dirty <= 0;
			spc_st    <= SPC_ADDR;
		end else if (spc_busy) begin
			case (spc_st)
			SPC_ADDR: begin
				spr_a  <= {spc_i, spc_byte};
				spc_st <= SPC_WAIT;
			end
			SPC_WAIT: begin
				spc_st <= SPC_CAPTURE;
			end
			SPC_CAPTURE: begin
				case (spc_byte)
				2'd0: spc_b0 <= spr_q;
				2'd1: spc_b1 <= spr_q;
				2'd2: spc_b2 <= spr_q;
				default: ;
				endcase
				if (spc_byte == 2'd3) begin
					// Character 0 is blank in both ROM sets, so records that
					// decode to it are dropped here rather than costing a scan
					// slot on every line.  Attribute bit 7 supplies the code MSB.
					if ((spc_b1[7:1] != 0) || (spc_b2[7] != 0)) begin
						spc_mem[spc_count[8:0]] <= {spr_q, spc_b2, spc_b1, spc_b0};
						spc_count <= spc_count + 1'd1;
					end
					if (spc_i == 9'd511) begin
						// Retry a dirty pass while there is still time for a
						// full 2.4-line attempt before the vcnt-15 deadline.
						if (spc_dirty && (vcnt >= 9'd250 || vcnt <= 9'd12)) begin
							spc_i     <= 0;
							spc_byte  <= 0;
							spc_count <= 0;
							spc_dirty <= 0;
							spc_retry_cnt <= spc_retry_cnt + 1'd1;
							spc_st    <= SPC_ADDR;
						end else begin
							spc_busy  <= 0;
							spc_valid <= 1;
							spc_st    <= SPC_IDLE;
							if (spc_dirty)
								spc_pub_dirty_cnt <= spc_pub_dirty_cnt + 1'd1;
						end
					end else begin
						spc_i    <= spc_i + 1'd1;
						spc_byte <= 0;
						spc_st   <= SPC_ADDR;
					end
				end else begin
					spc_byte <= spc_byte + 1'd1;
					spc_st   <= SPC_ADDR;
				end
			end
			default: spc_st <= SPC_IDLE;
			endcase
		end

		// A sub-CPU write during a pass taints it.  Placed after the state
		// machine so a write in the same cycle as a retry's dirty-clear wins;
		// a write in the cycle a pass publishes merely leaves a stale flag,
		// which the next start clears before its first read.
		if (spr_wr_stb && spc_busy) spc_dirty <= 1'b1;

		// The pass prepares bg_line = vcnt+1, so it must run for vcnt in
		// [VB_END-1, VB_START-2] to cover displayed lines VB_END..VB_START-1.
		// Gating on !vblank started it a line late, leaving the first visible
		// line with a sprite buffer nobody had cleared or written.
		if (ce_pix && hcnt == 9'd1 && spc_valid && !sp_busy &&
		    (vcnt >= VB_END - 1'd1) && (vcnt < VB_START - 1'd1)) begin
			sp_i    <= 0;
			sp_clr  <= 0;
			sp_st   <= SP_CLR;
			sp_busy <= 1;
			sp_wsel <= bg_wsel;
		end else if (sp_busy && (sp_st == SP_CLR || !bg_busy)) begin
			case (sp_st)
			SP_CLR: begin
				spr_we_r    <= 1'b1;
				spr_waddr_r <= sp_clr;
				spr_wdata_r <= 10'h3FF;
				if (sp_clr >= 8'd247) begin
					sp_st <= SP_PRIME;
					sp_i  <= 0;
				end else
					sp_clr <= sp_clr + 8'd1;
			end

			// The snapshot lives in BRAM, so its read address is registered.
			// Prime the pipeline, then keep it one record ahead so the steady
			// state is still one cycle per rejected sprite.
			SP_PRIME: begin
				if (spc_count == 0) begin
					sp_busy <= 0;
					sp_st   <= SP_IDLE;
				end else begin
					spc_rd_a <= sp_i;
					sp_st    <= SP_PRIME2;
				end
			end
			SP_PRIME2: begin
				spc_rd_a <= sp_i + 9'd1;
				sp_st    <= SP_SCAN;
			end

			SP_SCAN: begin
				begin : scan_sprite
					reg signed [9:0] xs;
					reg signed [9:0] ys;
					reg [7:0] row_now;
					reg [7:0] c_y, c_code, c_attr, c_x;
					// spc_rd_q holds record sp_i; spc_rd_a is already on sp_i+1.
					c_y    = spc_rd_q[7:0];
					c_code = spc_rd_q[15:8];
					c_attr = spc_rd_q[23:16];
					c_x    = spc_rd_q[31:24];

					// MAME:
					//   if (flip) x = 240 - x; else y = 224 - y;
					//   x &= 0xff;  y &= 0xff;
					//   if (x > 248) x -= 256;
					//   if (y > 240) y -= 256;
					// The mask comes *before* the comparison.  Skipping it let a
					// flipped sprite with x > 240 go negative and slide off the
					// left edge instead of wrapping to the right, which showed up
					// as differences in the last few columns under flip.
					xs = flipscreen ? (10'sd240 - $signed({2'b0, c_x})) : $signed({2'b0, c_x});
					ys = flipscreen ? $signed({2'b0, c_y}) : (10'sd224 - $signed({2'b0, c_y}));
					xs = $signed({2'b0, xs[7:0]});
					ys = $signed({2'b0, ys[7:0]});
					if (xs > 10'sd248) xs = xs - 10'sd256;
					if (ys > 10'sd240) ys = ys - 10'sd256;
					row_now = bg_line[7:0] - ys[7:0];
					if (row_now < 8'd32) begin
						sp_xs        <= xs;
						sp_ys        <= ys;
						sp_row       <= row_now;
						sp_y         <= c_y;
						sp_codeb     <= c_code;
						sp_at        <= c_attr;
						sp_x         <= c_x;
						sp_code_full <= {c_attr[7], c_code[7:1]};
						sp_phase     <= 0;
						sp_st        <= SP_FETCH;
					end else if (sp_i == (spc_count[8:0] - 9'd1)) begin
						sp_busy <= 0;
						sp_st   <= SP_IDLE;
					end else begin
						sp_i     <= sp_i + 1'd1;
						spc_rd_a <= sp_i + 9'd2;
					end
				end
			end
			SP_FETCH: begin
				if (sp_phase == 4'd0) begin
					begin : rowflip
						reg [7:0] rr;
						rr = flipscreen ? (8'd31 - sp_row) : sp_row;
						sp_row_off <= (rr < 8'd16) ? {8'b0, rr} : ({8'b0, rr} + 16'd16);
						sprite_a   <= ({8'b0, sp_code_full} << 6) + ((rr < 8'd16) ? {8'b0, rr} : ({8'b0, rr} + 16'd16));
					end
					// Transparency depends on the colour, which is fixed for
					// the whole character, so one fetch per sprite suffices.
					sp_trans_a <= sp_at[5:0];
					sp_phase <= 1;
				end else if (sp_phase == 4'd1) begin
					sp_phase <= 2;
				end else if (sp_phase == 4'd2) begin
					sp_trans_mask <= spr_trans_q;
					s0l <= sprite_q;
					sprite_a <= 16'h4000 + ({8'b0, sp_code_full} << 6) + sp_row_off;
					sp_phase <= 3;
				end else if (sp_phase == 4'd3) begin
					sp_phase <= 4;
				end else if (sp_phase == 4'd4) begin
					s1l <= sprite_q;
					sprite_a <= 16'h8000 + ({8'b0, sp_code_full} << 6) + sp_row_off;
					sp_phase <= 5;
				end else if (sp_phase == 4'd5) begin
					sp_phase <= 6;
				end else if (sp_phase == 4'd6) begin
					s2l <= sprite_q;
					sprite_a <= ({8'b0, sp_code_full} << 6) + sp_row_off + 16'd16;
					sp_phase <= 7;
				end else if (sp_phase == 4'd7) begin
					sp_phase <= 8;
				end else if (sp_phase == 4'd8) begin
					s0r <= sprite_q;
					sprite_a <= 16'h4000 + ({8'b0, sp_code_full} << 6) + sp_row_off + 16'd16;
					sp_phase <= 9;
				end else if (sp_phase == 4'd9) begin
					sp_phase <= 10;
				end else if (sp_phase == 4'd10) begin
					s1r <= sprite_q;
					sprite_a <= 16'h8000 + ({8'b0, sp_code_full} << 6) + sp_row_off + 16'd16;
					sp_phase <= 11;
				end else if (sp_phase == 4'd11) begin
					sp_phase <= 12;
				end else begin
					s2r <= sprite_q;
					sp_st <= SP_DRAW;
					sp_px <= 0;
					sp_phase <= 0;
				end
			end
			SP_DRAW: begin
				begin : draw1
					reg [2:0] pix;
					reg [2:0] bx;
					reg [7:0] b0, b1, b2;
					reg signed [9:0] xd;
					reg [3:0] src;
					src = flipscreen ? (4'd15 - sp_px) : sp_px;
					if (src < 4'd8) begin
						b0 = s0l; b1 = s1l; b2 = s2l;
						bx = src[2:0];
						pix = {b0[bx], b1[bx], b2[bx]};
					end else begin
						b0 = s0r; b1 = s1r; b2 = s2r;
						bx = src[2:0];
						pix = {b0[bx], b1[bx], b2[bx]};
					end
					// MAME uses transpen_mask(gfx, color, 0): a pen is skipped
					// when its colour-table entry is 0.  That is not the same
					// as "pixel value 0" -- 16 of the 512 sprite pens have a
					// non-zero pixel value and a zero table entry.
					//
					// Punch-through pens (table entry 0 with pen 7) are the
					// exception: MAME *does* write them, so they erase sprites
					// drawn earlier, and the palette stage then falls back to
					// the background.
					if (!sp_trans_mask[pix] || (pix == 3'd7)) begin
						xd = sp_xs + $signed({6'b0, sp_px});
						// Same raster space as the BG write above.
						if (xd >= 10'sd0 && xd < 10'sd248) begin
							spr_we_r    <= 1'b1;
							spr_waddr_r <= xd[7:0];
							spr_wdata_r <= {1'b0, sp_at[5:0], pix};
						end
					end
				end
				if (sp_px == 4'd15) begin
					if (sp_i == (spc_count[8:0] - 9'd1)) begin
						sp_busy <= 0;
						sp_st   <= SP_IDLE;
					end else begin
						// Re-prime the snapshot read for the next record.
						sp_i  <= sp_i + 1'd1;
						sp_st <= SP_PRIME;
					end
				end else
					sp_px <= sp_px + 1'd1;
			end
			default: begin sp_st <= SP_IDLE; sp_busy <= 0; end
			endcase
		end

		// Hard stop at the end of the line.  Past this point the buffers swap,
		// so a pass still running would write into the buffer being displayed
		// and the next line's pass would never start (sp_busy still set).
		// Dropping the remaining sprites keeps the failure local and
		// deterministic; spr_overflow records that it happened.
		if (ce_pix && (hcnt == H_TOTAL - 1'd1) && sp_busy) begin
			sp_busy      <= 1'b0;
			sp_st        <= SP_IDLE;
			spr_overflow <= 1'b1;
		end
	end
end

// =========================================================================
// Composite + multi-cycle PROM RGB decode
// =========================================================================
// The palette is resolved in two registered memory reads:
//   1. colour table   prom_lut[pen]            -> ctab
//   2. palette        pal_r/g/b[ctab]          -> RGB, all three in parallel
//
// Each read costs two cycles now that ikki_rom registers its addresses, so a
// normal pixel takes four of the seven cycles between pixel enables and a
// punch-through pixel (which repeats step 1 for the background pen) takes six.
// Splitting the three colour PROMs apart is what buys that headroom; reading
// them one after another left the pipeline with no slack at all.
localparam PAL_IDLE  = 3'd0;
localparam PAL_LUT0  = 3'd1;   // colour-table read in flight
localparam PAL_LUT1  = 3'd2;   // ctab available, issue palette read
localparam PAL_RGB0  = 3'd3;   // palette read in flight
localparam PAL_RGB1  = 3'd4;   // RGB available

reg [2:0] pal_st;
reg [9:0] cur_pen, bg_pen_r;
reg [3:0] r_r, g_r, b_r;
reg [3:0] r_out, g_out, b_out;
reg       is_sprite;
reg       punch_done;

reg [9:0] lut_a;
reg [7:0] pal_a;
assign lut_addr = lut_a;
assign pal_addr = pal_a;

// r_out is registered once more, so gate it with the blanking one pixel enable
// ahead of the outputs; after that register the two line up.
wire active = ~hb_sr[RGB_DELAY-2] & ~vb_sr[RGB_DELAY-2];

// The line buffers are indexed in MAME's raster space, which starts HB_END
// pixels left of the visible area, so visible column c lives at index c+HB_END
// and the last visible column is at index HB_START-1.  The compositor also
// runs FETCH_LEAD raster positions ahead of the pixel it is producing.
//
// Gating the fetch on the *visible* window made fetch_x span 0..239, so the
// eight right-most entries -- the whole of tilemap column 30, which MAME places
// at raster 240..247 -- were written by the renderer and then never read.
localparam FETCH_LEAD = HB_END;

wire fetch_active = (hcnt_next >= HB_END + FETCH_LEAD) &&
                    (hcnt_next < HB_START + FETCH_LEAD) &&
                    (vcnt >= VB_END) && (vcnt < VB_START);

// Linebuf q lags 1 clk; hcnt is stable between ce_pix so address is held long enough.
wire       mask_col = bufsel ? lb_mask1[fetch_x[7:3]] : lb_mask0[fetch_x[7:3]];
wire [9:0] spr_pen  = bufsel ? spr1_q : spr0_q;
wire [9:0] bg_pen   = bufsel ? bg1_q  : bg0_q;
wire       spr_empty = (spr_pen == 10'h3FF);
wire       take_bg   = mask_col | spr_empty;
wire [9:0] first_pen = take_bg ? bg_pen : spr_pen;

// MAME XORs the sprite colour table and leaves the background one alone.
wire [7:0] ctab_now = is_sprite ? (lut_q ^ 8'hFF) : lut_q;

always @(posedge clk) begin
	if (reset) begin
		pal_st <= PAL_IDLE;
		r_out <= 0; g_out <= 0; b_out <= 0;
		r_r <= 0; g_r <= 0; b_r <= 0;
		lut_a <= 0; pal_a <= 0;
		punch_done <= 0;
	end else if (ce_pix) begin
		r_out <= active ? r_r : 4'h0;
		g_out <= active ? g_r : 4'h0;
		b_out <= active ? b_r : 4'h0;

		if (fetch_active) begin
			bg_pen_r   <= bg_pen;
			cur_pen    <= first_pen;
			is_sprite  <= ~take_bg;
			lut_a      <= first_pen;
			punch_done <= 1'b0;
			pal_st     <= PAL_LUT0;
		end else
			pal_st <= PAL_IDLE;
	end else begin
		case (pal_st)
		PAL_LUT0: pal_st <= PAL_LUT1;
		PAL_LUT1: begin
			// A sprite pen whose colour-table entry is 0 and whose pen index is
			// 7 is MAME's punch-through: it shows the background instead.  Pens
			// with a zero entry and a different index never reach here; they are
			// dropped at draw time by the transparency mask.
			if (is_sprite && !punch_done &&
			    (cur_pen[2:0] == 3'b111) && (ctab_now == 8'h00)) begin
				cur_pen    <= bg_pen_r;
				is_sprite  <= 1'b0;
				lut_a      <= bg_pen_r;
				punch_done <= 1'b1;
				pal_st     <= PAL_LUT0;
			end else begin
				pal_a  <= ctab_now;
				pal_st <= PAL_RGB0;
			end
		end
		PAL_RGB0: pal_st <= PAL_RGB1;
		PAL_RGB1: begin
			r_r    <= pal_r_q[3:0];
			g_r    <= pal_g_q[3:0];
			b_r    <= pal_b_q[3:0];
			pal_st <= PAL_IDLE;
		end
		default: pal_st <= PAL_IDLE;
		endcase
	end
end

assign r = r_out;
assign g = g_out;
assign b = b_out;

wire _unused = |{sp_x, sp_y, sp_codeb, sp_ys};

endmodule
