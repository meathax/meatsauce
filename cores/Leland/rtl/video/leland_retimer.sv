// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - CRT frame retimer (DDR3 frame store, photometric V size)
//
//  Decouples the analog output timing from the game's native timing
//  (424x256 @ 65.955 Hz) so a CRT sees standard NTSC 240p while the game,
//  CPUs and sound keep running at full speed.
//
//  Write side : samples the game's video (rgb + HBlank/VBlank) on the game's
//               ce_pix and stores each active pixel in 16 bits: the BGR 2-3-3
//               palette byte for the older boards or the 4-4-4 palette word for
//               the Ataxx/WSF boards (g_ax). The 24-bit expansion of either is
//               exactly reversible. Four pixels are packed into one 64-bit word
//               and written to DDR3.
//  Read side  : profile 0 preserves the original /7, 436x262 schedule.
//               Profiles 1/2 use fixed /8 and 452x264 for the nominal
//               diagnostic and exact 630 MHz / 11 target roots.
//
//  Frame store: three 320x240 frames (153600 B each) in the HPS DDR3, through
//  the framework's DDRAM port, instead of ~225 M10K blocks. The only block
//  RAM used is two small line buffers and the gamma ROM.
//  Layout (64-bit word index): {frame[1:0], line*80 + x/4}, 32768 words per
//  frame, at DDR byte address 0x38000000 (the ROM staging area used by the
//  fast loader is at 0x30000000, see leland_ddr_loader.sv).
//
//  Frame handover: three buffers (write / last-completed / display). The
//  reader switches to the newest completed frame only as it enters vertical
//  blank, so it never tears. The game is faster than the reader, so about one
//  game frame in eleven is never displayed.
//
//  Line fetch: while output line n is displayed, the two source lines needed
//  for line n+1 are read from DDR3 into a ping-pong pair of line buffers
//  (~63 us per line available vs ~1-2 us of DDR3 time needed).
//
//  Photometric V Size resamples the 240 source lines onto N (<=240) active
//  output lines with a 2-tap bilinear blend in linear light, then re-encodes.
//  The selected profile's total line/frame cadence stays fixed; only the
//  active height and vertical blanking change. N=240 is bit-exact.
//
//  `stop` keeps this module off the DDR3 bus (used while the ROM is being
//  loaded / replayed by leland_ddr_loader). Everything is on clk_sys
//  (DDRAM_CLK = clk_sys), so there is no clock-domain crossing.
//============================================================================

module leland_retimer
#(
	parameter GAMMA_HEX = "rtl/video/gamma_inv.hex",
	parameter integer TARGET_CLOCK_PROFILE = 0
)
(
	input             clk_sys,

	// Hold off all DDR3 activity (ROM download / replay in progress)
	input             stop,

	// Game (source) side
	input             g_ce_pix,
	input             g_hblank,
	input             g_vblank,
	input      [23:0] g_rgb,
	input             g_ax,

	// Vertical position (OSD): 0..12 = move picture up that many lines,
	// 13..15 = move it down 3..1 lines. Done by moving vsync later/earlier
	// inside the fixed blanking.
	input       [3:0] vpos,

	// Photometric vertical size (OSD): active output lines
	// 240,236,232,228,224,220,216,208 for 0..7
	input       [2:0] vsize,

	// Retimed (output) side -- drive CE_PIXEL / VGA_* from these
	output reg        o_ce_pix,
	output reg        o_hblank,
	output reg        o_hsync,
	output reg        o_vblank,
	output reg        o_vsync,
	output reg [23:0] o_rgb,

	// Framework DDR3 port (Avalon-MM, 64-bit)
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output reg [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output reg        DDRAM_WE,

	// sticky, set if the write FIFO ever overflowed
	output reg        wf_overflow
);

assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_BE       = 8'hFF;

localparam [16:0] FRAME_PIX = 17'd76800; // 320 x 240

localparam integer OUTPUT_DIV = (TARGET_CLOCK_PROFILE == 0) ? 7 : 8;
localparam [2:0]  OUTPUT_DIV_LAST = OUTPUT_DIV - 1;
localparam [9:0] H_TOTAL  = (TARGET_CLOCK_PROFILE == 0) ? 10'd436 : 10'd452;
localparam [9:0] H_ACTIVE = 10'd320;
localparam [9:0] H_SYNC_S = 10'd342;
localparam [9:0] H_SYNC_E = 10'd390;

localparam [8:0] V_TOTAL  = (TARGET_CLOCK_PROFILE == 0) ? 9'd262 : 9'd264;

initial wf_overflow = 1'b0;

`ifndef SYNTHESIS
initial begin
	if (TARGET_CLOCK_PROFILE < 0 || TARGET_CLOCK_PROFILE > 2)
		$fatal(1, "leland_retimer: unsupported TARGET_CLOCK_PROFILE=%0d", TARGET_CLOCK_PROFILE);
end
`endif

//------------------------------------------------------------------
// Vertical size table
//   nact  : active output lines
//   ystep : source lines per output line, 8.12 fixed point (240/nact)
//   y0    : source position of output line 0, (step-1)/2
//   half  : (240-nact)/2, back-porch lengthening that keeps it centred
//------------------------------------------------------------------
reg [8:0]  nact;
reg [19:0] ystep;
reg [19:0] y0;
reg [4:0]  half;
always @* begin
	case (vsize)
		3'd1:    begin nact = 9'd236; ystep = 20'd4165; y0 = 20'd35;  half = 5'd2;  end
		3'd2:    begin nact = 9'd232; ystep = 20'd4237; y0 = 20'd71;  half = 5'd4;  end
		3'd3:    begin nact = 9'd228; ystep = 20'd4312; y0 = 20'd108; half = 5'd6;  end
		3'd4:    begin nact = 9'd224; ystep = 20'd4389; y0 = 20'd146; half = 5'd8;  end
		3'd5:    begin nact = 9'd220; ystep = 20'd4468; y0 = 20'd186; half = 5'd10; end
		3'd6:    begin nact = 9'd216; ystep = 20'd4551; y0 = 20'd228; half = 5'd12; end
		3'd7:    begin nact = 9'd208; ystep = 20'd4726; y0 = 20'd315; half = 5'd16; end
		default: begin nact = 9'd240; ystep = 20'd4096; y0 = 20'd0;   half = 5'd0;  end
	endcase
end

// vsync start = nact + 3 + half, moved by vpos (0..12 later, 13..15 earlier)
wire [8:0] vsync_base = nact + 9'd3 + {4'd0, half};
wire [8:0] vsync_s = (vpos <= 4'd12) ? (vsync_base + {5'd0, vpos})
                                     : (vsync_base - {5'd0, (4'd0 - vpos)});
wire [8:0] vsync_e = vsync_s + 9'd3;

//------------------------------------------------------------------
// Buffer bookkeeping (frames live in DDR3)
//   wbuf : being written by the game
//   lbuf : newest completed frame
//   rbuf : being displayed
// pending is set when lbuf holds a frame the reader hasn't shown yet. A
// publish landing on the same clock as a swap wins (the swap took the
// previous lbuf, so the new one is still pending).
//------------------------------------------------------------------
reg [1:0] wbuf    = 2'd0;
reg [1:0] lbuf    = 2'd1;
reg [1:0] rbuf    = 2'd1;
reg       pending = 1'b0;
reg       display_valid = 1'b0;

//------------------------------------------------------------------
// Reader timing (declared first: the writer needs swap_now)
//------------------------------------------------------------------
reg [2:0]  ocnt = 3'd0;
reg [9:0]  hc   = 10'd0;
reg [8:0]  vc   = 9'd0;

wire o_tick   = (ocnt == OUTPUT_DIV_LAST);
wire o_active = (hc < H_ACTIVE) && (vc < nact);
// Swap to the newest completed frame as the reader enters vertical blank.
wire swap_now = o_tick && (hc == 10'd0) && (vc == nact) && pending;

//------------------------------------------------------------------
// Write side: pack 8 pixels -> one 64-bit word -> 16-deep FIFO -> DDR3
//------------------------------------------------------------------
wire        g_de   = ~g_hblank & ~g_vblank;
wire [15:0] g_col16 = g_ax ? {4'd0, g_rgb[23:20], g_rgb[15:12], g_rgb[7:4]}
                           : {8'd0, g_rgb[7:6], g_rgb[15:13], g_rgb[23:21]};

reg        g_vb_d  = 1'b0;
reg [16:0] woff    = 17'd0;
reg [47:0] wsh     = 48'd0;   // pixels 0..2 of the word being assembled
reg        frame_armed = 1'b0, frame_bad = 1'b0;
reg        drain_pending = 1'b0, drain_valid = 1'b0;

wire       g_vb_rise  = g_vblank & ~g_vb_d;
wire       g_vb_fall  = ~g_vblank & g_vb_d;
wire       frame_done = g_vb_rise && (woff == FRAME_PIX) && frame_armed && !frame_bad;
wire [1:0] rbuf_n     = swap_now ? lbuf : rbuf;

reg [63:0] wf_data [0:15];
reg [16:0] wf_addr [0:15];
reg [3:0]  wf_wp  = 4'd0, wf_rp = 4'd0;
reg [4:0]  wf_cnt = 5'd0;
wire       wf_push;
wire       wf_pop;

wire       writes_drained = (wf_cnt == 0) && (!DDRAM_WE || !DDRAM_BUSY);
wire       capture_start = g_ce_pix && g_vb_fall && !stop && !drain_pending && writes_drained;
wire       pix_store = !stop && g_ce_pix && g_de &&
                       (frame_armed || capture_start) && (woff < FRAME_PIX);
wire       word_ready = pix_store && (woff[1:0] == 2'd3);
// A full FIFO must never overwrite its oldest queued command.
assign     wf_push = word_ready && ((wf_cnt < 16) || wf_pop);
wire       publish_now = !stop && drain_pending && drain_valid && writes_drained;

always @(posedge clk_sys) begin
	if (g_ce_pix) begin
		g_vb_d <= g_vblank;
		if (g_vb_fall) begin
			frame_armed <= capture_start;
			frame_bad <= 1'b0;
		end

		if (pix_store) begin
			woff <= woff + 1'd1;
			if (woff[1:0] != 2'd3)
				wsh[woff[1:0]*16 +: 16] <= g_col16;
		end

		if (g_vb_rise) begin
			woff <= 17'd0;
			frame_armed <= 1'b0;
			if (frame_armed) begin
				drain_pending <= 1'b1;
				drain_valid <= frame_done;
			end
		end
	end

	if (swap_now) begin
		rbuf <= lbuf;
		display_valid <= 1'b1;
		pending <= 1'b0;
	end
	// FIFO dequeue only issues a DDR command. Publish after its final
	// acceptance as well, including a simultaneous swap of the previous lbuf.
	if (!stop && drain_pending && writes_drained) begin
		drain_pending <= 1'b0;
		drain_valid <= 1'b0;
	end
	if (publish_now) begin
		lbuf <= wbuf;
		pending <= 1'b1;
		wbuf <= 2'd3 - wbuf - rbuf_n;
	end

	if (wf_push) begin
		wf_data[wf_wp] <= {g_col16, wsh};
		wf_addr[wf_wp] <= {wbuf, woff[16:2]};
		wf_wp          <= wf_wp + 1'd1;
	end
	if (wf_pop) wf_rp <= wf_rp + 1'd1;
	wf_cnt <= wf_cnt + {4'd0, wf_push} - {4'd0, wf_pop};
	if (word_ready && !wf_push) begin
		wf_overflow <= 1'b1;
		frame_bad <= 1'b1;
	end
	if (stop) begin
		frame_armed <= 1'b0;
		frame_bad <= 1'b0;
		drain_pending <= 1'b0;
		drain_valid <= 1'b0;
		woff <= 0;
		wf_wp <= 0;
		wf_rp <= 0;
		wf_cnt <= 0;
		pending <= 1'b0;
		display_valid <= 1'b0;
		wbuf <= 0;
		lbuf <= 1;
		rbuf <= 1;
	end
end

//------------------------------------------------------------------
// DDR3 command issue: FIFO writes have priority, then line-fetch reads.
// A command is held until accepted (RD/WE high and BUSY low at a clock
// edge); a new one may be loaded on that same edge.
//------------------------------------------------------------------
reg        rd_act   = 1'b0;   // line fetch has reads left to issue
reg        rd_which = 1'b0;   // 0: source line A, 1: source line B
reg [6:0]  rd_w     = 7'd0;   // word within the line (0..79)
reg [14:0] rowA_w   = 15'd0;  // word index of source line A within a frame
reg [14:0] rowB_w   = 15'd0;
reg [1:0]  fbuf     = 2'd0;   // frame buffer this fetch reads
reg [8:0]  fetch_line = 0;
reg [8:0]  reads_pending = 0;
reg        fetch_epoch_valid = 1'b0;
wire       fetch_start;
wire       nxt_wrap = (vc == V_TOTAL - 1'd1);
wire [8:0] nvc = nxt_wrap ? 9'd0 : vc + 1'd1;
wire       read_accept = DDRAM_RD && !DDRAM_BUSY;
wire       read_return = DDRAM_DOUT_READY && (reads_pending != 0 || read_accept);

// Return ownership survives stop: previously accepted DDR reads cannot be
// cancelled. Drain and discard that epoch before starting another line.
always @(posedge clk_sys) begin
	case ({read_accept, read_return})
		2'b10: reads_pending <= reads_pending + 1'b1;
		2'b01: reads_pending <= reads_pending - 1'b1;
		default: ;
	endcase
	if (stop) fetch_epoch_valid <= 1'b0;
	else if (fetch_start) fetch_epoch_valid <= 1'b1;
end

wire cmd_free = ~(DDRAM_RD | DDRAM_WE) | ~DDRAM_BUSY;

assign wf_pop = cmd_free && !stop && (wf_cnt != 5'd0);

wire [14:0] rd_row = rd_which ? rowB_w : rowA_w;

initial begin
	DDRAM_RD = 1'b0;
	DDRAM_WE = 1'b0;
end

always @(posedge clk_sys) begin
	if ((DDRAM_RD | DDRAM_WE) & ~DDRAM_BUSY) begin
		DDRAM_RD <= 1'b0;
		DDRAM_WE <= 1'b0;
	end

	if (stop) rd_act <= 1'b0;

	if (fetch_start) begin
		rd_act   <= 1'b1;
		rd_which <= 1'b0;
		rd_w     <= 7'd0;
	end

	if (cmd_free && !stop) begin
		if (wf_cnt != 5'd0) begin
			DDRAM_WE   <= 1'b1;
			DDRAM_ADDR <= {4'b0011, 1'b1, 7'd0, wf_addr[wf_rp]};
			DDRAM_DIN  <= wf_data[wf_rp];
		end else if (rd_act && !fetch_start) begin
			DDRAM_RD   <= 1'b1;
			DDRAM_ADDR <= {4'b0011, 1'b1, 7'd0, fbuf, rd_row + {8'd0, rd_w}};
			if (rd_w == 7'd79) begin
				rd_w <= 7'd0;
				if (rd_which) rd_act <= 1'b0;
				rd_which <= 1'b1;
			end else begin
				rd_w <= rd_w + 1'd1;
			end
		end
	end
end

//------------------------------------------------------------------
// Line buffers: two 64-bit x 256 RAMs (source line A / B), each holding
// two 80-word lines (ping-pong on line parity). DDR3 read responses arrive
// in order: first 80 words are line A, next 80 are line B.
//------------------------------------------------------------------
reg [63:0] lbA [0:255];
reg [63:0] lbB [0:255];
reg        r_fpar   = 1'b0;
reg        r_which  = 1'b0;
reg [6:0]  r_w      = 7'd0;
reg  [7:0] la;
reg [63:0] A_q, B_q;

wire dout_v = read_return && fetch_epoch_valid && !stop;
reg [1:0] line_valid = 0;
reg [8:0] line_tag [0:1];
reg [1:0] line_frame [0:1];
reg output_line_valid = 0;

always @(posedge clk_sys) begin
	if (fetch_start) begin
		r_which <= 1'b0;
		r_w     <= 7'd0;
		line_valid[nvc[0]] <= 1'b0;
	end else if (dout_v) begin
		if (r_w == 7'd79) begin
			r_w     <= 7'd0;
			r_which <= 1'b1;
			if (r_which) begin
				line_valid[r_fpar] <= 1'b1;
				line_tag[r_fpar] <= fetch_line;
				line_frame[r_fpar] <= fbuf;
			end
		end else begin
			r_w <= r_w + 1'd1;
		end
	end
	if (stop || swap_now) line_valid <= 0;
end

always @(posedge clk_sys) begin
	if (dout_v && !r_which) lbA[{r_fpar, r_w}] <= DDRAM_DOUT;
	A_q <= lbA[la];
end
always @(posedge clk_sys) begin
	if (dout_v && r_which) lbB[{r_fpar, r_w}] <= DDRAM_DOUT;
	B_q <= lbB[la];
end

//------------------------------------------------------------------
// Read side: geometry, line fetch trigger
//------------------------------------------------------------------
reg [19:0] y_n_r = 20'd0;   // source position of the line being displayed
reg  [4:0] fw_cur = 5'd0;   // blend weight (0..31) of the displayed line

wire [19:0] y_n      = nxt_wrap ? y0 : (y_n_r + ystep);
wire [7:0]  iA_n     = y_n[19:12];
wire [7:0]  iB_n     = (iA_n == 8'd239) ? iA_n : iA_n + 1'd1;

assign fetch_start = o_tick && (hc == 10'd0) && (nvc < nact) && !stop &&
                     display_valid && !rd_act && !DDRAM_RD && (reads_pending == 0);

// line index * 80 = (i << 6) + (i << 4)
wire [14:0] iA80 = {1'b0, iA_n, 6'd0} + {3'd0, iA_n, 4'd0};
wire [14:0] iB80 = {1'b0, iB_n, 6'd0} + {3'd0, iB_n, 4'd0};

always @(posedge clk_sys) begin
	if (fetch_start) begin
		y_n_r   <= y_n;
		rowA_w  <= iA80;
		rowB_w  <= iB80;
		fbuf    <= rbuf;
		r_fpar  <= nvc[0];
		fetch_line <= nvc;
	end
	// weight for the line that starts next: latch at line end
	if (o_tick && hc == H_TOTAL - 1'd1) fw_cur <= y_n_r[11:7];
end

//------------------------------------------------------------------
// Gamma tables (2.2). Source levels: R,G 3 bits, B 2 bits, or 4 bits per channel
// on the Ataxx/WSF boards, -> 12-bit linear.
// The inverse ROM (12-bit linear -> 8-bit) is generated with the exact
// source levels forced to round-trip, so weight 32/0 is bit-exact.
//------------------------------------------------------------------
function [11:0] lin_rg(input [2:0] i);
	case (i)
		3'd0: lin_rg = 12'd0;
		3'd1: lin_rg = 12'd55;
		3'd2: lin_rg = 12'd261;
		3'd3: lin_rg = 12'd631;
		3'd4: lin_rg = 12'd1201;
		3'd5: lin_rg = 12'd1950;
		3'd6: lin_rg = 12'd2930;
		default: lin_rg = 12'd4095;
	endcase
endfunction
function [11:0] lin_b(input [1:0] i);
	case (i)
		2'd0: lin_b = 12'd0;
		2'd1: lin_b = 12'd365;
		2'd2: lin_b = 12'd1678;
		default: lin_b = 12'd4095;
	endcase
endfunction

function [11:0] lin4(input [3:0] i);
	case (i)
		4'd0: lin4 = 12'd0;
		4'd1: lin4 = 12'd11;
		4'd2: lin4 = 12'd49;
		4'd3: lin4 = 12'd119;
		4'd4: lin4 = 12'd224;
		4'd5: lin4 = 12'd365;
		4'd6: lin4 = 12'd545;
		4'd7: lin4 = 12'd766;
		4'd8: lin4 = 12'd1027;
		4'd9: lin4 = 12'd1331;
		4'd10: lin4 = 12'd1678;
		4'd11: lin4 = 12'd2070;
		4'd12: lin4 = 12'd2506;
		4'd13: lin4 = 12'd2989;
		4'd14: lin4 = 12'd3518;
		default: lin4 = 12'd4095;
	endcase
endfunction

reg [7:0] inv_rom [0:4095];
initial $readmemh(GAMMA_HEX, inv_rom);

reg [11:0] rom_a;
reg  [7:0] rom_q;

//------------------------------------------------------------------
// Per-pixel pipeline (one output period is OUTPUT_DIV clocks):
//   period n : fetch source bytes A,B for pixel n from the line buffers
//              (address at ocnt 0, captured at ocnt 3); blend + re-encode
//              pixel n-1 (ocnt 0..5)
//   tick     : output pixel n-1 (blank flags delayed one pixel to match;
//              sync is not delayed, a one-pixel picture shift)
//------------------------------------------------------------------
reg [15:0] pA_r, pB_r;
reg [11:0] lin_r, lin_g, lin_bl;
reg  [7:0] o8_r, o8_g, o8_b;

wire [5:0]  wA = 6'd32 - {1'b0, fw_cur};
wire [5:0]  wB = {1'b0, fw_cur};

function [11:0] mix(input [11:0] a, input [11:0] b, input [5:0] wa, input [5:0] wb);
	reg [18:0] t;
	begin
		t   = a * wa + b * wb + 19'd16;
		mix = t[16:5];
	end
endfunction

reg pipe_active = 1'b0, pipe_hb = 1'b1, pipe_vb = 1'b1;
wire line_ready = display_valid && line_valid[vc[0]] &&
                  line_tag[vc[0]] == vc && line_frame[vc[0]] == rbuf && !stop;

always @(posedge clk_sys) begin
	ocnt     <= o_tick ? 3'd0 : ocnt + 1'd1;
	o_ce_pix <= o_tick;

	// line buffer read address for pixel hc (current line parity)
	la <= {vc[0], hc[8:2]};

	if (ocnt == 3'd3) begin
		pA_r <= A_q[hc[1:0]*16 +: 16];
		pB_r <= B_q[hc[1:0]*16 +: 16];
	end

	// linear-light blend of the two source lines
	if (ocnt == 3'd0) begin
		if (g_ax) begin
			lin_r  <= mix(lin4(pA_r[11:8]), lin4(pB_r[11:8]), wA, wB);
			lin_g  <= mix(lin4(pA_r[7:4]),  lin4(pB_r[7:4]),  wA, wB);
			lin_bl <= mix(lin4(pA_r[3:0]),  lin4(pB_r[3:0]),  wA, wB);
		end else begin
			lin_r  <= mix(lin_rg(pA_r[2:0]), lin_rg(pB_r[2:0]), wA, wB);
			lin_g  <= mix(lin_rg(pA_r[5:3]), lin_rg(pB_r[5:3]), wA, wB);
			lin_bl <= mix(lin_b (pA_r[7:6]), lin_b (pB_r[7:6]), wA, wB);
		end
	end

	// gamma re-encode through one shared ROM, one channel per clock
	case (ocnt)
		3'd1: rom_a <= lin_r;
		3'd2: rom_a <= lin_g;
		3'd3: rom_a <= lin_bl;
		default: ;
	endcase
	rom_q <= inv_rom[rom_a];
	case (ocnt)
		3'd3: o8_r <= rom_q;
		3'd4: o8_g <= rom_q;
		3'd5: o8_b <= rom_q;
		default: ;
	endcase

	if (o_tick) begin
		o_rgb    <= pipe_active && !stop ? {o8_r, o8_g, o8_b} : 24'd0;
		o_hblank <= pipe_hb;
		o_vblank <= pipe_vb;
		o_hsync  <= (hc >= H_SYNC_S) && (hc < H_SYNC_E);
		o_vsync  <= (vc >= vsync_s) && (vc < vsync_e);

		if (hc == 0) output_line_valid <= line_ready;
		pipe_active <= o_active && ((hc == 0) ? line_ready : output_line_valid);
		pipe_hb     <= (hc >= H_ACTIVE);
		pipe_vb     <= (vc >= nact);

		if (hc == H_TOTAL - 1'd1) begin
			hc <= 10'd0;
			vc <= (vc == V_TOTAL - 1'd1) ? 9'd0 : vc + 1'd1;
		end else begin
			hc <= hc + 1'd1;
		end
	end
end

endmodule
