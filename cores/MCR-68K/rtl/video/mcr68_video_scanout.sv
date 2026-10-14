`timescale 1ns/10ps
`default_nettype none

// Coherent MiSTer presentation boundary. The game remains a 512x480, ~30
// frame/s producer; the presentation cadence is selectable, with each
// completed frame repeated twice at ~60 frame/s by default or presented once
// at the native cadence when requested.
// The completed frames live in the core-owned DDRAM window below. Only a
// single scanline is kept in FPGA logic, so the presentation path no longer
// consumes hundreds of M10Ks for a second copy of video memory.
//
// DDRAM is accessed as 64-bit words containing eight 8-bit lanes. Only the
// low six bits of each lane are used. The four high address bits select the
// same 0x30000000 MiSTer DDRAM region used by the project-owned DDRAM
// adapters; the low 25 bits are an eight-byte word index. This core is the
// only DDRAM client in sys_top, and the three frame banks occupy 3*30720 words
// starting at FRAME_BASE_WORD.
module mcr68_video_scanout #(
	parameter int VIDEO_CLK_HZ = 100_000_000,
	parameter int VIDEO_DOT_HZ = 10_000_000,
	parameter int H_TOTAL      = 634,
	parameter int V_TOTAL      = 512,
	parameter int H_ACTIVE     = 512,
	parameter int V_ACTIVE     = 480
) (
	input  logic        game_clk,
	input  logic        video_clk,
	input  logic        rst,

	output logic        DDRAM_CLK,
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic        DDRAM_WE,

	input  logic        game_enable,
	input  logic        game_ce,
	input  logic [8:0]  game_y,
	input  logic        game_hblank,
	input  logic        game_vblank,
	input  logic [5:0]  game_index,
	input  logic [8:0]  game_rgb,
	input  logic        present_x2,
	input  logic        direct_video,
	output logic       present_x2_active,
	output logic       pixel_x2_active,
	output logic        out_ce,
	output logic        out_hblank,
	output logic        out_vblank,
	output logic        out_hsync,
	output logic        out_vsync,
	output logic [7:0]  out_r,
	output logic [7:0]  out_g,
	output logic [7:0]  out_b
);
	localparam int FRAME_WORDS  = H_ACTIVE * V_ACTIVE / 8;
	localparam int LINE_WORDS   = H_ACTIVE / 8;
	// The renderer cannot be back-pressured without changing the native raster.
	// Keep enough accepted-word history to cover bounded DDRAM waitrequest
	// bursts; a faulted frame is discarded rather than displayed partially.
	localparam int FIFO_DEPTH   = 64;
	localparam int FIFO_PTR_W   = $clog2(FIFO_DEPTH);
	localparam logic [24:0] FRAME_BASE_WORD = 25'h0001_000;
	localparam int LINE_REQ_DEPTH = 16;
	localparam int LINE_REQ_PTR_W = $clog2(LINE_REQ_DEPTH);
	localparam int LINE_REQ_SEQ_W = LINE_REQ_PTR_W + 1;

	assign DDRAM_CLK = game_clk;
	// BURSTCNT is per-request: 1 for frame-word writes, LINE_WORDS for the
	// line refill read burst (registered alongside the command below).
	// 2026-08-26 hardware root-cause: the refill used to issue 64 SEPARATE
	// single-beat reads inside one ~12.2 us horizontal blank.  Each beat pays
	// the full HPS DDR3 request latency, and refill also queued behind the
	// frame-write drain, so on real hardware the line store was frequently
	// not ready when the active line started -- line_ready_now gated the
	// early pixels to black and the picture showed ragged black tearing at
	// the LEFT edge, worst on busy frames.  The simulation model answered
	// reads in one cycle, so no harness ever saw it.  One read burst brings
	// the whole line in with a single request latency.

	// -------------------------------------------------------------------------
	// Presentation timing. The requested mode is committed only during VBlank;
	// the raster totals and frame-bank ownership are unchanged by the rate.
	// -------------------------------------------------------------------------
	logic rst_video;
	logic [1:0] rst_video_pipe;
	always_ff @(posedge video_clk) begin
		if (rst) begin
			rst_video_pipe <= 2'b11;
			rst_video      <= 1'b1;
		end else begin
			rst_video_pipe <= {rst_video_pipe[0], 1'b0};
			rst_video      <= rst_video_pipe[1];
		end
	end

	// Raster status from the timing generator below.
	wire scan_hblank, scan_vblank, scan_hsync_n, scan_vsync_n;

	logic [31:0] dot_acc;
	logic present_x2_r;
	logic [2:0] direct_video_sync;
	logic pixel_x2_r;
	assign present_x2_active = present_x2_r;
	assign pixel_x2_active   = pixel_x2_r;
	wire [31:0] dot_rate = present_x2_r ? (VIDEO_DOT_HZ * 2) : VIDEO_DOT_HZ;
	logic scan_ce;
	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			dot_acc <= 32'd0;
			scan_ce <= 1'b0;
			present_x2_r <= 1'b1;
			direct_video_sync <= 3'b000;
			pixel_x2_r <= 1'b1;
		end else begin
			direct_video_sync <= {direct_video_sync[1:0], direct_video};
			if (scan_vblank && (pixel_x2_r == direct_video_sync[2]))
				pixel_x2_r <= ~direct_video_sync[2];
			if (scan_vblank && (present_x2_r != present_x2)) begin
				dot_acc <= 32'd0;
				scan_ce <= 1'b0;
				present_x2_r <= present_x2;
			end else if (dot_acc + dot_rate >= VIDEO_CLK_HZ) begin
				dot_acc <= dot_acc + dot_rate - VIDEO_CLK_HZ;
				scan_ce <= 1'b1;
			end else begin
				dot_acc <= dot_acc + dot_rate;
				scan_ce <= 1'b0;
			end
		end
	end

	logic [9:0] scan_x, scan_y;
	logic [8:0] scan_pixel_x, scan_pixel_y;
	/* verilator lint_off UNUSEDSIGNAL */
	logic timing_vblank_pulse, timing_hsync_pulse;
	/* verilator lint_on UNUSEDSIGNAL */
	mcr68_video_timing #(
		.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL),
		.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE)
	) u_timing (
		.clk(video_clk), .rst(rst_video), .ce_dot(scan_ce),
		.h_count(scan_x), .v_count(scan_y),
		.hblank(scan_hblank), .vblank(scan_vblank),
		.hsync_n(scan_hsync_n), .vsync_n(scan_vsync_n),
		.pixel_x(scan_pixel_x), .pixel_y(scan_pixel_y),
		.vblank_pulse(timing_vblank_pulse), .hsync_pulse(timing_hsync_pulse)
	);

	// -------------------------------------------------------------------------
	// Game-side frame packer and write FIFO.
	// -------------------------------------------------------------------------
	logic [8:0] palette0 [0:63];
	logic [8:0] palette1 [0:63];
	logic [8:0] palette2 [0:63];
	logic [63:0] pack_data;
	logic [2:0]  pack_slot;
	logic [15:0] pack_word;
	logic [1:0] write_bank;
	logic ready_toggle, game_vblank_d;

	logic [63:0] fifo_data [0:FIFO_DEPTH-1];
	logic [24:0] fifo_addr [0:FIFO_DEPTH-1];
	logic [1:0]  fifo_bank [0:FIFO_DEPTH-1];
	logic [FIFO_PTR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
	logic [FIFO_PTR_W:0] fifo_count;
	localparam logic [FIFO_PTR_W:0] FIFO_DEPTH_COUNT = FIFO_DEPTH[FIFO_PTR_W:0];
	wire fifo_empty = (fifo_count == 0);
	wire fifo_full  = (fifo_count == FIFO_DEPTH_COUNT);

	typedef enum logic [2:0] {
		MEM_IDLE,
		MEM_WRITE_STREAM,
		MEM_WRITE_GAP,
		MEM_READ_REQ,
		MEM_READ_WAIT
	} mem_state_t;
	mem_state_t mem_state;

	// Line requests cross from video_clk to game_clk through an asynchronous
	// FIFO. The payload is written before the Gray pointer is visible in the
	// other clock domain, so it is stable when consumed.
	logic [10:0] line_req_data [0:LINE_REQ_DEPTH-1];
	logic [LINE_REQ_SEQ_W-1:0] line_req_wr_bin, line_req_wr_gray;
	logic [LINE_REQ_SEQ_W-1:0] line_req_rd_bin, line_req_rd_gray;
	logic [LINE_REQ_SEQ_W-1:0] line_req_wr_gray_sync1, line_req_wr_gray_sync2;
	logic [LINE_REQ_SEQ_W-1:0] line_req_rd_gray_sync1, line_req_rd_gray_sync2;

	function automatic logic [LINE_REQ_SEQ_W-1:0] line_req_bin_to_gray(
		input logic [LINE_REQ_SEQ_W-1:0] value
	);
		line_req_bin_to_gray = (value >> 1) ^ value;
	endfunction

	wire line_req_available = (line_req_wr_gray_sync2 != line_req_rd_gray);
	wire [10:0] line_req_head = line_req_data[line_req_rd_bin[LINE_REQ_PTR_W-1:0]];
	wire [1:0] line_req_pending_bank = line_req_head[10:9];
	wire [8:0] line_req_pending_y = line_req_head[8:0];
	wire line_start = (mem_state == MEM_IDLE) && line_req_available;
	wire line_req_full =
		(line_req_bin_to_gray(line_req_wr_bin + 1'b1) ==
		 {~line_req_rd_gray_sync2[LINE_REQ_SEQ_W-1:LINE_REQ_SEQ_W-2],
		  line_req_rd_gray_sync2[LINE_REQ_SEQ_W-3:0]});
	// A write beat is accepted on any cycle where WE is presented and the
	// bridge is not busy (Avalon-MM); the pop advances the head so the next
	// beat's data is on DDRAM_DIN the following cycle.  The old engine pulsed
	// WE/RD one cycle AFTER sampling !BUSY, so a beat could be silently
	// dropped whenever BUSY rose in between -- hold-until-accepted removes
	// that race.
	wire fifo_pop = (mem_state == MEM_WRITE_STREAM) && !DDRAM_BUSY;

	// Longest run of address-contiguous FIFO entries at the head (max 8).
	// The producer emits strictly sequential words within a bank, so runs
	// are long; bursting them cuts the per-transaction HPS-bridge overhead
	// ~8x, which matters because this core shares that DDR3 with the ascal
	// HDMI scaler -- single-beat write hammering starved the scaler's line
	// FIFO and showed up as dropped-pixel corruption on the display that
	// never appears in native captures.
	logic [3:0] wr_contig;
	always_comb begin
		wr_contig = 4'd1;
		for (int k = 1; k < 8; k++) begin
			if ((fifo_count > (FIFO_PTR_W+1)'(k)) &&
			    (fifo_addr[FIFO_PTR_W'(fifo_rd_ptr + FIFO_PTR_W'(k))] ==
			     (fifo_head_addr + 25'(k))) &&
			    (wr_contig == 4'(k)))
				wr_contig = 4'(k + 1);
		end
	end

	function automatic logic [24:0] frame_word_address(
		input logic [1:0] bank,
		input logic [15:0] word_index
	);
		logic [24:0] bank_offset;
		begin
			case (bank)
				2'd0: bank_offset = 25'd0;
				2'd1: bank_offset = FRAME_WORDS[24:0];
				default: bank_offset = 25'(FRAME_WORDS * 2);
			endcase
			frame_word_address = FRAME_BASE_WORD + bank_offset +
			                     {9'd0, word_index};
		end
	endfunction

	function automatic logic [63:0] insert_pixel(
		input logic [63:0] word,
		input logic [2:0]  slot,
		input logic [5:0]  index
	);
		logic [63:0] result;
		begin
			result = word;
			result[(slot * 8) +: 8] = {2'b00, index};
			insert_pixel = result;
		end
	endfunction

	logic [1:0] display_bank_game_sync1, display_bank_game_sync2;
	logic [2:0] consumed_toggle_game_sync;
	logic [1:0] display_bank_game;
	logic consumed_toggle_game_seen, display_valid_game;
	always_ff @(posedge game_clk) begin
		if (rst) begin
			display_bank_game_sync1 <= 2'd0;
			display_bank_game_sync2 <= 2'd0;
			consumed_toggle_game_sync <= 3'b000;
			display_bank_game <= 2'd0;
			consumed_toggle_game_seen <= 1'b0;
			display_valid_game <= 1'b0;
		end else begin
			display_bank_game_sync1 <= display_bank;
			display_bank_game_sync2 <= display_bank_game_sync1;
			consumed_toggle_game_sync <= {consumed_toggle_game_sync[1:0], consumed_toggle};
			if (consumed_toggle_game_sync[2] != consumed_toggle_game_seen) begin
				display_bank_game <= display_bank_game_sync2;
				consumed_toggle_game_seen <= consumed_toggle_game_sync[2];
				display_valid_game <= 1'b1;
			end
		end
	end
	wire producer_bank_conflict =
		(display_valid_game && (write_bank == display_bank_game)) ||
		(frame_ready_pending && (write_bank == frame_ready_bank)) ||
		(ready_inflight && (write_bank == ready_bank_payload));
	localparam logic [8:0] V_ACTIVE_GAME = V_ACTIVE[8:0];
	localparam logic [9:0] H_ACTIVE_SCAN = H_ACTIVE[9:0];
	localparam logic [9:0] V_ACTIVE_SCAN = V_ACTIVE[9:0];
	wire fb_write_window = game_enable && game_ce && !game_hblank &&
	                       !game_vblank && (game_y < V_ACTIVE_GAME);
	wire fb_we = fb_write_window && !producer_bank_conflict;
	wire pack_commit = fb_we && (pack_slot == 3'd7);
	wire [63:0] pack_commit_data = insert_pixel(pack_data, pack_slot, game_index);
	wire fifo_push_allowed = pack_commit && (!fifo_full || fifo_pop);

	// Per-bank counts make the ready toggle wait until every write belonging
	// to that completed frame has been accepted by the DDRAM bridge.
	logic [15:0] bank_outstanding0, bank_outstanding1, bank_outstanding2;
	logic frame_ready_pending;
	logic [1:0] frame_ready_bank, ready_bank_payload;
	logic ready_inflight;
	logic frame_write_fault;

	always_ff @(posedge game_clk) begin
		if (rst) begin
			fifo_wr_ptr <= '0;
			fifo_rd_ptr <= '0;
			fifo_count  <= '0;
		end else begin
			if (fifo_push_allowed) begin
				fifo_data[fifo_wr_ptr] <= pack_commit_data;
				fifo_addr[fifo_wr_ptr] <= frame_word_address(write_bank, pack_word);
				fifo_bank[fifo_wr_ptr] <= write_bank;
				fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
			end
			if (fifo_pop)
				fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
			case ({fifo_push_allowed, fifo_pop})
				2'b10: fifo_count <= fifo_count + 1'b1;
				2'b01: fifo_count <= fifo_count - 1'b1;
				default: fifo_count <= fifo_count;
			endcase
		end
	end

	wire [63:0] fifo_head_data = fifo_data[fifo_rd_ptr];
	wire [24:0] fifo_head_addr = fifo_addr[fifo_rd_ptr];
	wire [1:0]  fifo_head_bank = fifo_bank[fifo_rd_ptr];

	always_ff @(posedge game_clk) begin
		if (rst) begin
			bank_outstanding0 <= 16'd0;
			bank_outstanding1 <= 16'd0;
			bank_outstanding2 <= 16'd0;
		end else begin
			case ({fifo_push_allowed && (write_bank == 2'd0),
			       fifo_pop && (fifo_head_bank == 2'd0)})
				2'b10: bank_outstanding0 <= bank_outstanding0 + 1'b1;
				2'b01: bank_outstanding0 <= bank_outstanding0 - 1'b1;
				default: ;
			endcase
			case ({fifo_push_allowed && (write_bank == 2'd1),
			       fifo_pop && (fifo_head_bank == 2'd1)})
				2'b10: bank_outstanding1 <= bank_outstanding1 + 1'b1;
				2'b01: bank_outstanding1 <= bank_outstanding1 - 1'b1;
				default: ;
			endcase
			case ({fifo_push_allowed && (write_bank == 2'd2),
			       fifo_pop && (fifo_head_bank == 2'd2)})
				2'b10: bank_outstanding2 <= bank_outstanding2 + 1'b1;
				2'b01: bank_outstanding2 <= bank_outstanding2 - 1'b1;
				default: ;
			endcase
		end
	end

	wire frame_ready_drained =
		((frame_ready_bank == 2'd0) && (bank_outstanding0 == 0)) ||
		((frame_ready_bank == 2'd1) && (bank_outstanding1 == 0)) ||
		((frame_ready_bank == 2'd2) && (bank_outstanding2 == 0));

	always_ff @(posedge game_clk) begin
		if (rst) begin
			pack_data           <= 64'd0;
			pack_slot           <= 3'd0;
			pack_word           <= 16'd0;
			write_bank          <= 2'd0;
			ready_toggle        <= 1'b0;
			game_vblank_d       <= 1'b1;
			frame_ready_pending <= 1'b0;
			frame_ready_bank    <= 2'd0;
			ready_bank_payload  <= 2'd0;
			ready_inflight      <= 1'b0;
			frame_write_fault   <= 1'b0;
		end else begin
			game_vblank_d <= game_vblank;
			if (fb_write_window && producer_bank_conflict)
				frame_write_fault <= 1'b1;
			if (ready_inflight &&
			    (consumed_toggle_game_sync[2] == ready_toggle))
				ready_inflight <= 1'b0;

			if (game_vblank && !game_vblank_d && game_enable) begin
				if (!frame_write_fault && pack_slot == 0 &&
				    pack_word == 16'd30720 && !frame_ready_pending) begin
					// Publish only a complete, non-faulted bank. The ready event
					// is delayed until all of its DDRAM writes are accepted.
					frame_ready_pending <= 1'b1;
					frame_ready_bank    <= write_bank;
				end else begin
				`ifndef SYNTHESIS
					if (!frame_write_fault &&
					    (pack_slot != 0 || pack_word != 16'd30720))
						$fatal(1, "incomplete packed video frame");
				`endif
				end
				frame_write_fault   <= 1'b0;
				write_bank          <= (write_bank == 2'd2) ? 2'd0 :
				                       (write_bank + 1'b1);
				pack_data           <= 64'd0;
				pack_slot           <= 3'd0;
				pack_word           <= 16'd0;
			end else if (fb_we) begin
				if (pack_commit) begin
					if (fifo_push_allowed) begin
						pack_data <= 64'd0;
						pack_slot <= 3'd0;
						pack_word <= pack_word + 1'b1;
					end else begin
						// The producer cannot be stalled. Discard this word but
						// advance the phase so later words remain lane-aligned;
						// the incomplete bank is rejected at the next vblank.
						frame_write_fault <= 1'b1;
						pack_data <= 64'd0;
						pack_slot <= 3'd0;
						pack_word <= pack_word + 1'b1;
					end
				end else begin
					pack_data <= insert_pixel(pack_data, pack_slot, game_index);
					pack_slot <= pack_slot + 1'b1;
				end
			end

			if (frame_ready_pending && frame_ready_drained &&
			    (!ready_inflight ||
			     (consumed_toggle_game_sync[2] == ready_toggle))) begin
				ready_bank_payload  <= frame_ready_bank;
				ready_toggle        <= ~ready_toggle;
				ready_inflight      <= 1'b1;
				frame_ready_pending <= 1'b0;
			end
		end
	end

	// -------------------------------------------------------------------------
	// -------------------------------------------------------------------------
	// Lossless line-request CDC. The video side queues the bank/line payload;
	// the game side consumes it only when the memory engine accepts a request.
	// -------------------------------------------------------------------------
	logic [1:0] line_req_src_bank;
	logic [8:0] line_req_src_y;
	logic line_req_event;

	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			line_req_rd_gray_sync1 <= '0;
			line_req_rd_gray_sync2 <= '0;
			line_req_wr_bin        <= '0;
			line_req_wr_gray      <= '0;
		end else begin
			line_req_rd_gray_sync1 <= line_req_rd_gray;
			line_req_rd_gray_sync2 <= line_req_rd_gray_sync1;
			if (line_req_event) begin
				if (!line_req_full) begin
					line_req_data[line_req_wr_bin[LINE_REQ_PTR_W-1:0]] <=
						{line_req_src_bank, line_req_src_y};
					line_req_wr_bin  <= line_req_wr_bin + 1'b1;
					line_req_wr_gray <= line_req_bin_to_gray(line_req_wr_bin + 1'b1);
				end else begin
				`ifndef SYNTHESIS
					$fatal(1, "line request FIFO overflow");
				`endif
				end
			end
		end
	end

	always_ff @(posedge game_clk) begin
		if (rst) begin
			line_req_wr_gray_sync1 <= '0;
			line_req_wr_gray_sync2 <= '0;
			line_req_rd_bin        <= '0;
			line_req_rd_gray      <= '0;
		end else begin
			line_req_wr_gray_sync1 <= line_req_wr_gray;
			line_req_wr_gray_sync2 <= line_req_wr_gray_sync1;
			if (line_start) begin
				line_req_rd_bin  <= line_req_rd_bin + 1'b1;
				line_req_rd_gray <= line_req_bin_to_gray(line_req_rd_bin + 1'b1);
			end
		end
	end
	always_ff @(posedge game_clk) begin
		if (fb_we && (write_bank == 2'd0))
			palette0[game_index] <= game_rgb;
		if (fb_we && (write_bank == 2'd1))
			palette1[game_index] <= game_rgb;
		if (fb_we && (write_bank == 2'd2))
			palette2[game_index] <= game_rgb;
	end

	// Three small line stores are deliberately kept in logic. They are only
	// 3*64*48 bits and avoid turning the line refill mechanism into another
	// M10K-sized RAM. The system side writes a completed line; video reads the
	// same bank after the done toggle has crossed back.
	(* ramstyle = "M10K, no_rw_check" *) logic [47:0] line_words0 [0:LINE_WORDS-1];
	(* ramstyle = "M10K, no_rw_check" *) logic [47:0] line_words1 [0:LINE_WORDS-1];
	(* ramstyle = "M10K, no_rw_check" *) logic [47:0] line_words2 [0:LINE_WORDS-1];
	logic [1:0] line_target_bank;
	logic [8:0] line_target_y;
	logic [5:0] line_word_index;
	logic line_done_toggle;
	logic [1:0] line_done_bank;
	logic [8:0] line_done_y;

	// Low-level DDRAM command engine.  WE/RD/DIN are combinational off the
	// state and FIFO head so every command/beat is HELD until the bridge
	// accepts it (!BUSY on the same cycle) -- Avalon-MM hold-until-accepted.
	logic [3:0] wr_beats_left;
	wire [47:0] line_word_unpack = {
		DDRAM_DOUT[56 +: 6], DDRAM_DOUT[48 +: 6],
		DDRAM_DOUT[40 +: 6], DDRAM_DOUT[32 +: 6],
		DDRAM_DOUT[24 +: 6], DDRAM_DOUT[16 +: 6],
		DDRAM_DOUT[8 +: 6], DDRAM_DOUT[0 +: 6]};
	wire [15:0] ddram_reserved_bits = {
		DDRAM_DOUT[63:62], DDRAM_DOUT[55:54],
		DDRAM_DOUT[47:46], DDRAM_DOUT[39:38],
		DDRAM_DOUT[31:30], DDRAM_DOUT[23:22],
		DDRAM_DOUT[15:14], DDRAM_DOUT[7:6]};
	assign DDRAM_DIN = fifo_head_data;
	assign DDRAM_WE  = (mem_state == MEM_WRITE_STREAM);
	assign DDRAM_RD  = (mem_state == MEM_READ_REQ);
	always_ff @(posedge game_clk) begin
		if (rst) begin
			mem_state        <= MEM_IDLE;
			line_target_bank <= 2'd0;
			line_target_y    <= 9'd0;
			line_word_index  <= 6'd0;
			line_done_toggle <= 1'b0;
			line_done_bank   <= 2'd0;
			line_done_y      <= 9'd0;
			DDRAM_ADDR       <= 29'd0;
			DDRAM_BE         <= 8'd0;
			DDRAM_BURSTCNT   <= 8'd1;
			wr_beats_left    <= 4'd0;
		end else begin
			case (mem_state)
				MEM_IDLE: begin
					// The refill has a hard deadline (next active line); the
					// write FIFO has none and can absorb a whole line, so a
					// pending line request is served FIRST.
					if (line_start) begin
						line_target_bank <= line_req_pending_bank;
						line_target_y    <= line_req_pending_y;
						line_word_index  <= 6'd0;
						// One whole-line read burst from the line's base word.
						DDRAM_ADDR <= {4'b0011,
							frame_word_address(line_req_pending_bank,
								{1'b0, line_req_pending_y, 6'd0})};
						DDRAM_BE       <= 8'hff;
						DDRAM_BURSTCNT <= LINE_WORDS[7:0];
						mem_state      <= MEM_READ_REQ;
					end else if (!fifo_empty) begin
						// Contiguous head run becomes one write burst; the
						// first beat's data is already on DDRAM_DIN.
						DDRAM_ADDR     <= {4'b0011, fifo_head_addr};
						DDRAM_BE       <= 8'hff;
						DDRAM_BURSTCNT <= {4'd0, wr_contig};
						wr_beats_left  <= wr_contig;
						mem_state      <= MEM_WRITE_STREAM;
					end
				end

				MEM_WRITE_STREAM: begin
					// fifo_pop (beat accepted) advances DDRAM_DIN to the next
					// head automatically.
					if (fifo_pop) begin
						wr_beats_left <= wr_beats_left - 1'b1;
						if (wr_beats_left == 4'd1)
							mem_state <= MEM_WRITE_GAP;
					end
				end

				MEM_WRITE_GAP: begin
					mem_state <= MEM_IDLE;
				end

				MEM_READ_REQ: begin
					// Command held until the bridge accepts it.
					if (!DDRAM_BUSY)
						mem_state <= MEM_READ_WAIT;
				end

				MEM_READ_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						case (line_target_bank)
							2'd0: line_words0[line_word_index] <= line_word_unpack;
							2'd1: line_words1[line_word_index] <= line_word_unpack;
							default: line_words2[line_word_index] <= line_word_unpack;
						endcase

						if (line_word_index == 6'(LINE_WORDS-1)) begin
							line_done_bank   <= line_target_bank;
							line_done_y      <= line_target_y;
							line_done_toggle <= ~line_done_toggle;
							mem_state        <= MEM_IDLE;
						end else begin
							line_word_index <= line_word_index + 1'b1;
						end
					end
				end
				default: mem_state <= MEM_IDLE;
			endcase
		end
	end

	// -------------------------------------------------------------------------
	// Video-side frame handoff, line request scheduler and response CDC.
	// -------------------------------------------------------------------------
	logic [2:0] ready_toggle_sync;
	logic [1:0] ready_bank_sync1, ready_bank_sync2;
	logic consumed_toggle;
	logic [1:0] display_bank;
	logic display_valid;
	logic scan_hblank_d, scan_vblank_d;
	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			ready_toggle_sync <= 3'b000;
			ready_bank_sync1  <= 2'd0;
			ready_bank_sync2  <= 2'd0;
			consumed_toggle   <= 1'b0;
			display_bank      <= 2'd0;
			display_valid     <= 1'b0;
			scan_hblank_d     <= 1'b0;
			scan_vblank_d     <= 1'b0;
			line_req_event    <= 1'b0;
			line_req_src_bank <= 2'd0;
			line_req_src_y    <= 9'd0;
		end else begin
			line_req_event    <= 1'b0;
			ready_bank_sync1  <= ready_bank_payload;
			ready_bank_sync2  <= ready_bank_sync1;
			ready_toggle_sync <= {ready_toggle_sync[1:0], ready_toggle};
			scan_hblank_d     <= scan_hblank;
			scan_vblank_d     <= scan_vblank;

			// A new completed bank may be consumed only in output blanking.
			if (scan_vblank && ready_toggle_sync[2] != consumed_toggle) begin
				display_bank    <= ready_bank_sync2;
				consumed_toggle <= ready_toggle_sync[2];
				display_valid   <= 1'b1;
				line_req_src_bank <= ready_bank_sync2;
				line_req_src_y    <= 9'd0;
				line_req_event    <= 1'b1;
			end else if (scan_vblank && !scan_vblank_d) begin
				// Refill line zero for a repeated frame as well. This keeps
				// the external-bank contract explicit even when no new toggle
				// arrived during this vblank.
				line_req_src_bank <= display_bank;
				line_req_src_y    <= 9'd0;
				line_req_event    <= 1'b1;
			end else if (scan_hblank && !scan_hblank_d &&
			             scan_y < (V_ACTIVE_SCAN - 10'd1)) begin
				// The just-finished active line is no longer being read, so
				// its bank's small line store may be refilled for the next
				// line throughout this horizontal blanking interval.
				line_req_src_bank <= display_bank;
				line_req_src_y    <= scan_pixel_y + 1'b1;
				line_req_event    <= 1'b1;
			end
		end
	end

	logic [2:0] line_done_toggle_sync;
	logic line_done_seen;
	logic [1:0] line_done_bank_sync1, line_done_bank_sync2;
	logic [8:0] line_done_y_sync1, line_done_y_sync2;
	logic [1:0] line_ready_bank;
	logic [8:0] line_ready_y;
	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			line_done_toggle_sync <= 3'b000;
			line_done_seen        <= 1'b0;
			line_done_bank_sync1  <= 2'd0;
			line_done_bank_sync2  <= 2'd0;
			line_done_y_sync1     <= 9'd0;
			line_done_y_sync2     <= 9'd0;
			line_ready_bank       <= 2'd0;
			line_ready_y          <= 9'd0;
		end else begin
			line_done_toggle_sync <= {line_done_toggle_sync[1:0], line_done_toggle};
			line_done_bank_sync1  <= line_done_bank;
			line_done_bank_sync2  <= line_done_bank_sync1;
			line_done_y_sync1     <= line_done_y;
			line_done_y_sync2     <= line_done_y_sync1;
			if (line_done_toggle_sync[2] != line_done_seen) begin
				line_done_seen <= line_done_toggle_sync[2];
				line_ready_bank<= line_done_bank_sync2;
				line_ready_y   <= line_done_y_sync2;
			end
		end
	end

	function automatic logic [5:0] select_line_pixel(
		input logic [47:0] word,
		input logic [2:0]  slot
	);
		select_line_pixel = word[(slot * 6) +: 6];
	endfunction

	wire line_ready_now = (line_ready_bank == display_bank) &&
	                      (line_ready_y == scan_pixel_y);
	wire active_valid = (scan_x < H_ACTIVE_SCAN) && (scan_y < V_ACTIVE_SCAN) &&
	                    display_valid && line_ready_now;

	// The line-word RAM output is the first stage. Keep the slot, bank, valid
	// and raster controls beside it so the synchronous memory latency cannot
	// misalign colour with CE, blanking or sync.
	logic [47:0] line_word0_read_r;
	logic [47:0] line_word1_read_r;
	logic [47:0] line_word2_read_r;
	logic [2:0]  line_word_slot_r;
	logic [1:0]  line_word_bank_r;
	logic        line_active_valid_r;
	logic        line_scan_ce_r, line_scan_hblank_r, line_scan_vblank_r;
	logic        line_scan_hsync_r, line_scan_vsync_r;
	always_ff @(posedge video_clk) begin
		if (rst_video)
			line_word0_read_r <= 48'd0;
		else
			line_word0_read_r <= line_words0[scan_pixel_x[8:3]];
	end
	always_ff @(posedge video_clk) begin
		if (rst_video)
			line_word1_read_r <= 48'd0;
		else
			line_word1_read_r <= line_words1[scan_pixel_x[8:3]];
	end
	always_ff @(posedge video_clk) begin
		if (rst_video)
			line_word2_read_r <= 48'd0;
		else
			line_word2_read_r <= line_words2[scan_pixel_x[8:3]];
	end
	wire [47:0] line_word_read = (display_bank == 2'd0) ? line_word0_read_r :
	                              (display_bank == 2'd1) ? line_word1_read_r :
	                                                         line_word2_read_r;
	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			line_word_slot_r    <= 3'd0;
			line_word_bank_r    <= 2'd0;
			line_active_valid_r <= 1'b0;
			line_scan_ce_r      <= 1'b0;
			line_scan_hblank_r  <= 1'b1;
			line_scan_vblank_r  <= 1'b1;
			line_scan_hsync_r   <= 1'b0;
			line_scan_vsync_r   <= 1'b0;
		end else begin
			line_word_slot_r    <= scan_pixel_x[2:0];
			line_word_bank_r    <= display_bank;
			line_active_valid_r <= active_valid;
			line_scan_ce_r      <= scan_ce;
			line_scan_hblank_r  <= scan_hblank;
			line_scan_vblank_r  <= scan_vblank;
			line_scan_hsync_r   <= ~scan_hsync_n;
			line_scan_vsync_r   <= ~scan_vsync_n;
		end
	end

	wire [5:0] selected_index = select_line_pixel(line_word_read,
		                                             line_word_slot_r);

	// Split the line-word/index selection from the palette lookup. The
	// complete presentation bundle is delayed together so the RAM latency is
	// a pixel-phase-preserving latency, not a colour-only workaround.
	(* preserve, dont_retime *) logic [5:0] selected_index_r;
	logic [1:0] selected_bank_r;
	logic       active_valid_r;
	logic       scan_ce_r, scan_hblank_r, scan_vblank_r;
	logic       scan_hsync_r, scan_vsync_r;
	always_ff @(posedge video_clk) begin
		if (rst_video) begin
			selected_index_r <= 6'd0;
			selected_bank_r  <= 2'd0;
			active_valid_r   <= 1'b0;
			scan_ce_r        <= 1'b0;
			scan_hblank_r    <= 1'b1;
			scan_vblank_r    <= 1'b1;
			scan_hsync_r     <= 1'b0;
			scan_vsync_r     <= 1'b0;
		end else begin
			selected_index_r <= selected_index;
			selected_bank_r  <= line_word_bank_r;
			active_valid_r   <= line_active_valid_r;
			scan_ce_r        <= line_scan_ce_r;
			scan_hblank_r    <= line_scan_hblank_r;
			scan_vblank_r    <= line_scan_vblank_r;
			scan_hsync_r     <= line_scan_hsync_r;
			scan_vsync_r     <= line_scan_vsync_r;
		end
	end

	wire [8:0] selected_rgb =
		(selected_bank_r == 2'd0) ? palette0[selected_index_r] :
		(selected_bank_r == 2'd1) ? palette1[selected_index_r] :
		                               palette2[selected_index_r];

	// -------------------------------------------------------------------------
	// Horizontal pixel doubling on the presentation stream.
	//
	// MEASURED 2026-08-31 on hardware, from the user's 1920x1080 HDMI captures
	// with the core's own HV-Integer scale selected (exact 2x/2x geometry):
	//
	//   vertical   row-pair mean |delta| = 0.000  (bit-identical duplicated rows)
	//   horizontal col-pair mean |delta| = 47..57 at BOTH phases
	//
	// i.e. ascal duplicated rows exactly but interpolated every column. In
	// MiSTer.ini `vsync_adjust=2` low-latency mode ascal does not run its
	// vertical polyphase filter, but the HORIZONTAL polyphase filter is always
	// in the path. At a 2.0 horizontal ratio that filter emits alternating
	// exact/blended columns -- the "blurry pixels" reported for Arch Rivals,
	// Pigskin and Blasted, and the reason no scale, filter or integer-scaling
	// setting removed it.
	//
	// A polyphase filter is a unity tap only at phase 0, which happens for
	// EVERY output pixel when the scale ratio is exactly 1.0. So the core now
	// presents each source pixel as two identical output pixels: ascal sees a
	// 1024-wide input, HV Integer resolves to a 1024-wide output, the
	// horizontal ratio is 1.0, and no horizontal filtering is possible
	// regardless of the user's filter selection.
	//
	// This is done by issuing a SECOND out_ce in the middle of each dot. The
	// whole presentation bundle (colour, blanking, sync, active-valid) is
	// already held stable for the full dot period by the pipeline above, so
	// the extra enable republishes the identical pixel. Nothing in the raster,
	// the line store, the DDRAM schedule or the frame cadence changes: the
	// line period, hblank duration and 61.613 Hz frame rate are untouched, and
	// the horizontal blanking budget available to the line refill is the same
	// number of nanoseconds as before.
	//
	// Dot period in video_clk cycles is VIDEO_CLK_HZ/dot_rate: 5 at the
	// doubled 20 MHz presentation cadence, 10 at the native 10 MHz cadence.
	// The mid-dot enable is placed at half of that.
	//
	// Direct Video bypasses the CE-domain scaler. sys_top transmits the held
	// sample at CLK_VIDEO, so the 2/3-cycle cadence produced by a mid-dot
	// duplicate at 100/20 MHz becomes non-uniform physical pixel dwell. Keep
	// the native, uniform-dot stream on that path. The mode bit is synchronized
	// and committed during VBlank; it cannot change a displayed line.
	logic [7:0] mid_ce_sr;
	always_ff @(posedge video_clk) begin
		if (rst_video) mid_ce_sr <= 8'd0;
		else           mid_ce_sr <= {mid_ce_sr[6:0], scan_ce_r};
	end
	wire mid_ce = pixel_x2_r ? (present_x2_r ? mid_ce_sr[1] : mid_ce_sr[4]) : 1'b0;

	always_comb begin
		out_ce     = scan_ce_r | mid_ce;
		out_hblank = scan_hblank_r;
		out_vblank = scan_vblank_r;
		out_hsync  = scan_hsync_r;
		out_vsync  = scan_vsync_r;
		out_r      = active_valid_r ? {selected_rgb[8:6], selected_rgb[8:6], selected_rgb[8:7]} : 8'd0;
		out_g      = active_valid_r ? {selected_rgb[5:3], selected_rgb[5:3], selected_rgb[5:4]} : 8'd0;
		out_b      = active_valid_r ? {selected_rgb[2:0], selected_rgb[2:0], selected_rgb[2:1]} : 8'd0;
	end

`ifndef SYNTHESIS
	logic scan_ce_d;
	always_ff @(posedge video_clk) begin
		if (rst_video) scan_ce_d <= 1'b0;
		else scan_ce_d <= scan_ce;
		if (!rst_video && (timing_vblank_pulse || timing_hsync_pulse) && !scan_ce_d)
			$fatal(1, "video timing pulse without pixel enable");
		if (!rst_video && scan_ce && !scan_hblank && !scan_vblank &&
		    display_valid && !line_ready_now)
			$fatal(1, "DDRAM line underflow bank=%0d y=%0d ready_bank=%0d ready_y=%0d",
			       display_bank, scan_y, line_ready_bank, line_ready_y);
	end
	always_ff @(posedge game_clk) begin
		if (!rst) begin
			if (DDRAM_DOUT_READY && |ddram_reserved_bits)
				$fatal(1, "non-zero reserved bits in packed frame word");
			if (pack_commit && !fifo_push_allowed)
				$fatal(1, "DDRAM frame-write FIFO overflow");
			if (fb_we && display_valid_game &&
			    write_bank == display_bank_game)
				$fatal(1, "producer attempted to overwrite displayed bank");
			if (write_bank > 2'd2 || frame_ready_bank > 2'd2 ||
			    ready_bank_payload > 2'd2)
				$fatal(1, "invalid frame-bank identifier");
		end
	end
`endif
endmodule

`default_nettype wire
