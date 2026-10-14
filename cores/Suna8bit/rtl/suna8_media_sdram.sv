// Low-latency ROM storage for the MiSTer SDRAM expansion.
//
// The SDRAM command engine is derived from the MiSTer-devel Gameboy_MiSTer
// SDRAM controller by Sorgelig, itself based in part on the Hamsterworks
// Simple SDRAM Controller. This file is distributed under the GNU General
// Public License, version 3 or (at your option) any later version.
//
// Copyright (c) 2018 Sorgelig
// Copyright (c) 2026 Suna8bit contributors

module suna8_sdram_controller
(
	input  logic        clk,
	input  logic        reset,

	inout  wire [15:0]  SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_CLK,
	output logic        SDRAM_CKE,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_nWE,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCS,

	input  logic        req,
	input  logic        write,
	input  logic [24:0] addr,
	input  logic [15:0] din,
	output logic [63:0] dout,
	output logic        ready,
	output logic        busy,
	output logic        initialized
);

	localparam logic [3:0] CMD_INHIBIT = 4'b1111;
	localparam logic [3:0] CMD_NOP     = 4'b0111;
	localparam logic [3:0] CMD_ACTIVE  = 4'b0011;
	localparam logic [3:0] CMD_READ    = 4'b0101;
	localparam logic [3:0] CMD_WRITE   = 4'b0100;
	localparam logic [3:0] CMD_PRE     = 4'b0010;
	localparam logic [3:0] CMD_REFRESH = 4'b0001;
	localparam logic [3:0] CMD_MODE    = 4'b0000;

	// Burst length 4, sequential access, CAS latency 2, single writes.
	//
	// 2026-09-07 (hardware "very laggy" report): burst length 1 made every
	// read cost a full ACTIVE/READ/CAS/precharge transaction for two bytes.
	// At the 24 MHz core clock that is roughly eight clocks per 16-bit word,
	// about 3.0 M reads/s shared between seven clients, which is far below
	// what the three Z80s and the sprite renderer demand. The renderer's own
	// access pattern is the worst case: suna8_gfx_layout puts planes 0/1 and
	// planes 2/3 in halves of the gfx region megabytes apart, so a
	// single-word-per-client cache thrashed on every plane step. Reading a
	// four-word (eight byte) line per transaction covers four tile rows of a
	// plane at once (the layout advances two bytes per row), and the A9=1
	// single-location-write bit above keeps the download write path at one
	// word per command, so this affects reads only.
	// Burst length 1. The four words of a line are fetched as four single
	// READ commands inside one row activation instead of one burst-4 read:
	// the burst-4 window was never made to work on real hardware (two
	// alignments both failed the post-download CRC readback, R065/R067)
	// whereas this per-word capture point is the one the core booted with
	// for months. The line still costs a single ACTIVE and a single
	// precharge, so the cache line -- which is where most of the bandwidth
	// win came from -- is unaffected.
	localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'b000};
	localparam int BURST_WORDS = 4;
	localparam int POWERUP_CYCLES = 4_800; // 200 us at the 24 MHz core clock.
	// 160 clocks is 6.67 us. This leaves transaction headroom below the
	// 7.8125 us per-row refresh limit of the 32 MB MiSTer SDRAM module.
	localparam int REFRESH_CYCLES = 160;

	typedef enum logic [4:0] {
		ST_POWERUP, ST_PRECHARGE, ST_PRE_WAIT1, ST_PRE_WAIT2,
		ST_REFRESH1, ST_REF1_WAIT1, ST_REF1_WAIT2,
		ST_REFRESH2, ST_REF2_WAIT1, ST_REF2_WAIT2,
		ST_LOAD_MODE, ST_MODE_WAIT1, ST_MODE_WAIT2,
		ST_IDLE, ST_REFRESH, ST_REFRESH_WAIT1, ST_REFRESH_WAIT2,
		ST_ACTIVE_WAIT, ST_READ_WAIT1, ST_READ_WAIT2, ST_READ_WAIT3,
		ST_WRITE_WAIT1, ST_WRITE_WAIT2
	} state_t;

	state_t state;
	logic [1:0] read_word;
	logic [12:0] powerup_count;
	logic [8:0] refresh_count;
	logic [24:0] saved_addr;
	logic [15:0] saved_data;
	logic saved_write;
	logic req_pending;
	logic [24:0] pending_addr;
	logic [15:0] pending_data;
	logic pending_write;
	logic [3:0] command;
	logic [15:0] dq_out;
	logic dq_oe;

	assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
	assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = command;
	assign SDRAM_CKE = 1'b1;
	// On MiSTer's common 128 MB SDRAM module DQML/DQMH are physically tied
	// to A11/A12. Keep the FPGA outputs identical so they never fight the
	// module, and use full-word writes so both lanes remain enabled at CAS.
	// This also remains valid on 32 MB modules where the pins are independent.
	assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

	// Generate the SDRAM clock with the same Cyclone V primitive used by
	// established MiSTer SDRAM controllers. The inverted phase gives command
	// and address outputs half a clock to settle before SDRAM samples them.
	altddio_out
	#(
		.extend_oe_disable("OFF"),
		.intended_device_family("Cyclone V"),
		.invert_output("OFF"),
		.lpm_hint("UNUSED"),
		.lpm_type("altddio_out"),
		.oe_reg("UNREGISTERED"),
		.power_up_high("OFF"),
		.width(1)
	)
	u_sdram_clock
	(
		.datain_h(1'b0),
		.datain_l(1'b1),
		.outclock(clk),
		.dataout(SDRAM_CLK),
		.aclr(1'b0),
		.aset(1'b0),
		.oe(1'b1),
		.outclocken(1'b1),
		.sclr(1'b0),
		.sset(1'b0)
	);

	always_ff @(posedge clk) begin
		if (reset) begin
			state          <= ST_POWERUP;
			powerup_count  <= 13'd0;
			refresh_count  <= 9'd0;
			saved_addr     <= 25'd0;
			saved_data     <= 16'd0;
			saved_write    <= 1'b0;
			req_pending    <= 1'b0;
			pending_addr   <= 25'd0;
			pending_data   <= 16'd0;
			pending_write  <= 1'b0;
			command        <= CMD_INHIBIT;
			SDRAM_A        <= 13'd0;
			SDRAM_BA       <= 2'd0;
			dq_out         <= 16'd0;
			dq_oe          <= 1'b0;
			dout           <= 64'd0;
			read_word      <= 2'd0;
			ready          <= 1'b0;
			busy           <= 1'b1;
			initialized    <= 1'b0;
		end else begin
			command    <= CMD_NOP;
			dq_oe      <= 1'b0;
			ready      <= 1'b0;

			// Capture the single outstanding request independently of the
			// command state. A one-cycle request can coincide with refresh;
			// without this mailbox that transfer is lost and ioctl_wait stays
			// asserted forever. The media arbiter never issues a second request
			// before ready, so one entry is sufficient.
			if (req) begin
				req_pending   <= 1'b1;
				pending_addr  <= addr;
				pending_data  <= din;
				pending_write <= write;
			end

			if (initialized && refresh_count < REFRESH_CYCLES[8:0])
				refresh_count <= refresh_count + 9'd1;

			case (state)
				ST_POWERUP: begin
					busy    <= 1'b1;
					command <= CMD_NOP;
					if (powerup_count == POWERUP_CYCLES[12:0] - 13'd1) begin
						powerup_count <= 13'd0;
						state <= ST_PRECHARGE;
					end else begin
						powerup_count <= powerup_count + 13'd1;
					end
				end

				ST_PRECHARGE: begin
					command <= CMD_PRE;
					SDRAM_A <= 13'b0010000000000;
					state <= ST_PRE_WAIT1;
				end
				ST_PRE_WAIT1: state <= ST_PRE_WAIT2;
				ST_PRE_WAIT2: state <= ST_REFRESH1;

				ST_REFRESH1: begin command <= CMD_REFRESH; state <= ST_REF1_WAIT1; end
				ST_REF1_WAIT1: state <= ST_REF1_WAIT2;
				ST_REF1_WAIT2: state <= ST_REFRESH2;
				ST_REFRESH2: begin command <= CMD_REFRESH; state <= ST_REF2_WAIT1; end
				ST_REF2_WAIT1: state <= ST_REF2_WAIT2;
				ST_REF2_WAIT2: state <= ST_LOAD_MODE;

				ST_LOAD_MODE: begin
					command <= CMD_MODE;
					SDRAM_A <= MODE;
					SDRAM_BA <= 2'd0;
					state <= ST_MODE_WAIT1;
				end
				ST_MODE_WAIT1: state <= ST_MODE_WAIT2;
				ST_MODE_WAIT2: begin
					initialized <= 1'b1;
					refresh_count <= 9'd0;
					busy <= 1'b0;
					state <= ST_IDLE;
				end

				ST_IDLE: begin
					busy <= 1'b0;
					if (refresh_count >= REFRESH_CYCLES[8:0]) begin
						busy <= 1'b1;
						refresh_count <= 9'd0;
						command <= CMD_REFRESH;
						state <= ST_REFRESH_WAIT1;
				end else if (req_pending) begin
					busy        <= 1'b1;
					saved_addr  <= pending_addr;
					saved_data  <= pending_data;
					saved_write <= pending_write;
					req_pending <= 1'b0;
					SDRAM_BA    <= pending_addr[24:23];
					SDRAM_A     <= pending_addr[22:10];
						command     <= CMD_ACTIVE;
						state       <= ST_ACTIVE_WAIT;
					end
				end

				ST_REFRESH: begin
					command <= CMD_REFRESH;
					state <= ST_REFRESH_WAIT1;
				end
				ST_REFRESH_WAIT1: state <= ST_REFRESH_WAIT2;
				ST_REFRESH_WAIT2: begin busy <= 1'b0; state <= ST_IDLE; end

				ST_ACTIVE_WAIT: begin
					// A10 requests auto-precharge; A9 is unused for this
					// geometry. A read starts a four-word burst, so its two
					// low column bits are forced to the burst boundary and
					// the caller receives the whole aligned eight-byte line.
					// A write is still a single-location command (mode bit
					// A9 = 1), so it keeps the exact column it asked for.
					if (saved_write) begin
						SDRAM_A <= {2'b00, 2'b10, saved_addr[9:1]};
						command <= CMD_WRITE;
						dq_out <= saved_data;
						dq_oe <= 1'b1;
						state <= ST_WRITE_WAIT1;
					end else begin
						// Word 0 of the line. A10 = 0 keeps the row open for
						// the next three reads; the last one auto-precharges.
						read_word <= 2'd0;
						SDRAM_A <= {2'b00, 2'b00, saved_addr[9:3], 2'b00};
						command <= CMD_READ;
						state <= ST_READ_WAIT1;
					end
				end

				// One word per READ, captured at the point the single-word
				// design always used and the only one proven on real hardware.
				// Burst mode is deliberately not used: with burst length 4 the
				// words change every clock, and neither the original window nor
				// the window one clock later survived the post-download CRC
				// readback on hardware (R065/R067), while simulation passed
				// both because the device models had been written to match the
				// controller rather than the part.
				ST_READ_WAIT1: state <= ST_READ_WAIT2;
				ST_READ_WAIT2: state <= ST_READ_WAIT3;
				ST_READ_WAIT3: begin
					case (read_word)
						2'd0: dout[15:0]  <= SDRAM_DQ;
						2'd1: dout[31:16] <= SDRAM_DQ;
						2'd2: dout[47:32] <= SDRAM_DQ;
						default: dout[63:48] <= SDRAM_DQ;
					endcase
					if (read_word == 2'd3) begin
						ready <= 1'b1;
						busy <= 1'b0;
						state <= ST_IDLE;
					end else begin
						// Same row, next column. Auto-precharge only on the
						// final word so the row is closed exactly once.
						SDRAM_A <= {2'b00,
						            (read_word == 2'd2) ? 2'b10 : 2'b00,
						            saved_addr[9:3], (read_word + 2'd1)};
						command <= CMD_READ;
						read_word <= read_word + 2'd1;
						state <= ST_READ_WAIT1;
					end
				end

				ST_WRITE_WAIT1: state <= ST_WRITE_WAIT2;
				ST_WRITE_WAIT2: begin
					ready <= 1'b1;
					busy <= 1'b0;
					state <= ST_IDLE;
				end

				default: begin busy <= 1'b1; initialized <= 1'b0; state <= ST_POWERUP; end
			endcase
		end
	end

endmodule


module suna8_media_sdram
(
	input  logic        clk,
	input  logic        reset,
	input  logic        runtime_enable,
	input  logic        download_active,
	input  logic        verify_enable,
	input  logic [24:0] verify_size,
	input  logic [31:0] verify_expected_crc,
	output logic        media_ready,
	output logic        media_initialized,
	output logic        media_verify_active,
	output logic        media_verify_failed,
	// Sticky: a download byte was lost (FIFO overflow) or a half-written
	// byte pair was abandoned. Distinguishes "the host stream never reached
	// SDRAM intact" from a plain CRC mismatch on the boot diagnostic.
	output logic        media_bytes_dropped,
	output logic [31:0] media_verify_crc,
	output logic        media_busy,
	output logic [6:0]  debug_cache_miss,
	output logic        debug_transaction_active,

	input  logic        media_wr_valid,
	input  logic [24:0] media_wr_addr,
	input  logic [7:0]  media_wr_data,
	output logic        ioctl_wait,
	output logic        media_write_busy,

	input  logic [19:0] main_addr,
	input  logic        main_req,
	output logic [7:0]  main_q,
	output logic        main_ready,
	input  logic [15:0] sound_addr,
	input  logic        sound_req,
	output logic [7:0]  sound_q,
	output logic        sound_ready,
	input  logic [15:0] pcm_addr,
	input  logic        pcm_req,
	output logic [7:0]  pcm_q,
	output logic        pcm_ready,
	input  logic [19:0] gfx1_addr,
	output logic [7:0]  gfx1_q,
	// The whole 64-bit cache line containing gfx1_addr, valid with
	// gfx1_ready. A sprite tile row-pair (rows 0-3 or 4-7 of one plane pair)
	// is exactly one line, so the renderer takes it once instead of asking
	// for its eight bytes one at a time.
	output logic [63:0] gfx1_line_q,
	output logic        gfx1_ready,
	input  logic [19:0] gfx2_addr,
	output logic [7:0]  gfx2_q,
	output logic [63:0] gfx2_line_q,
	output logic        gfx2_ready,
	input  logic [15:0] sample_addr,
	output logic [7:0]  sample_q,
	output logic        sample_ready,
	input  logic [7:0]  prom_addr,
	output logic [7:0]  prom_q,
	output logic        prom_ready,

	inout  wire [15:0]  SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_CLK,
	output logic        SDRAM_CKE,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_nWE,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCS
);

	import suna8_media_pkg::*;

	localparam logic [24:0] MAIN_BASE    = 25'h000000;
	localparam logic [24:0] AUDIO_BASE   = 25'h080000;
	localparam logic [24:0] PCM_BASE     = 25'h090000;
	localparam logic [24:0] GFX1_BASE    = 25'h0a0000;
	localparam logic [24:0] GFX2_BASE    = 25'h1a0000;
	localparam logic [24:0] SAMPLES_BASE = 25'h2a0000;
	localparam logic [24:0] PROMS_BASE   = 25'h2b0000;
	localparam logic [3:0] CLIENT_WRITE  = 4'd7;
	localparam logic [3:0] CLIENT_VERIFY = 4'd8;

	wire [24:0] main_abs   = MAIN_BASE    + {5'd0, main_addr};
	wire [24:0] sound_abs  = AUDIO_BASE   + {9'd0, sound_addr};
	wire [24:0] pcm_abs    = PCM_BASE     + {9'd0, pcm_addr};
	wire [24:0] gfx1_abs   = GFX1_BASE    + {5'd0, gfx1_addr};
	wire [24:0] gfx2_abs   = GFX2_BASE    + {5'd0, gfx2_addr};
	wire [24:0] sample_abs = SAMPLES_BASE + {9'd0, sample_addr};
	wire [24:0] prom_abs   = PROMS_BASE   + {17'd0, prom_addr};

	// One eight-byte line per client, tagged by the line address
	// (absolute address bits 24:3). The controller returns a whole
	// four-word burst per transaction, so a line costs no more SDRAM time
	// than the single word it replaced while covering four times as much
	// sequentially accessed data.
	// Four ways per client. The sprite renderer alternates between the two
	// halves of the gfx region on every plane step (suna8_gfx_layout places
	// planes 0/1 and planes 2/3 megabytes apart), so a single line per client
	// is evicted on every one of those steps and never gets to serve the
	// three tile rows it already holds. The main Z80 needs more than two
	// because it interleaves sequential code fetch, table reads and its
	// banked ROM window; with two ways it still missed about half its reads.
	localparam int CACHE_WAYS = 4;
	logic [21:0] cache_tag [0:6][0:CACHE_WAYS-1];
	logic [63:0] cache_data [0:6][0:CACHE_WAYS-1];
	logic [6:0] cache_valid_way [0:CACHE_WAYS-1];
	logic [1:0] cache_way_next [0:6];
	logic [CACHE_WAYS-1:0] cache_hit [0:6];
	logic [1:0] cache_hit_way [0:6];
	wire [24:0] client_abs [0:6];

	function automatic logic [7:0] cache_byte(input logic [63:0] line,
	                                          input logic [2:0] sel);
		case (sel)
			3'd0: cache_byte = line[7:0];
			3'd1: cache_byte = line[15:8];
			3'd2: cache_byte = line[23:16];
			3'd3: cache_byte = line[31:24];
			3'd4: cache_byte = line[39:32];
			3'd5: cache_byte = line[47:40];
			3'd6: cache_byte = line[55:48];
			default: cache_byte = line[63:56];
		endcase
	endfunction
	logic [6:0] cache_miss;
	logic [2:0] round_robin;
	logic [3:0] selected_client;
	logic [3:0] active_client;
	logic [21:0] pending_tag;
	logic transaction_active;
	logic write_pair_valid;
	logic [24:0] write_pair_addr;
	logic [7:0] write_pair_low;

	// Incoming-byte elastic buffer. MiSTer's HPS-side ioctl_wait handshake
	// is not a same-cycle combinational stall: sys/hps_io.sv forwards
	// ioctl_wait to the ARM side over the HPS bridge and fires ioctl_wr
	// unconditionally on its own next strobe, so several bytes can already
	// be in flight by the time the host actually reacts to a wait assertion
	// (confirmed on real hardware: every game's post-download CRC readback
	// failed -- suna8_boot_diag's red/white-bar state -- while the
	// zero-latency Verilator host, which gates ioctl_wr on ioctl_wait in
	// the same evaluated cycle, never saw a problem). Previously
	// media_wr_valid bytes were consumed directly by the write-pair state
	// machine below with no buffering at all: any byte arriving while
	// !(!transaction_active && ctl_initialized && !ctl_busy) was silently
	// dropped, corrupting the pair machine and/or leaving a hole in the
	// downloaded image. This FIFO absorbs that round-trip latency; the
	// write-pair machine now drains it at the SDRAM's own pace instead of
	// coupling directly to the live ioctl bus.
	localparam int MEDIA_WR_FIFO_DEPTH = 128;
	localparam int MEDIA_WR_FIFO_AW = 7;
	// Assert ioctl_wait this many entries before the FIFO is actually
	// full, leaving margin for bytes already in flight when the host
	// reacts. The true HPS round-trip latency is unmeasured; a Verilator
	// host modelling an N-cycle-late wait observation (MISTER_IOCTL_WAIT_DELAY)
	// held clean through N=8 with a smaller (32-deep, 8-margin) FIFO and
	// failed at N=16, so this depth/margin is deliberately generous rather
	// than tuned to the minimum observed failure.
	localparam int MEDIA_WR_FIFO_WATERMARK = MEDIA_WR_FIFO_DEPTH - 64;
	logic [32:0] media_wr_fifo [0:MEDIA_WR_FIFO_DEPTH-1];
	logic [MEDIA_WR_FIFO_AW-1:0] media_wr_fifo_wr_ptr;
	logic [MEDIA_WR_FIFO_AW-1:0] media_wr_fifo_rd_ptr;
	logic [MEDIA_WR_FIFO_AW:0] media_wr_fifo_count;
	logic media_wr_fifo_push;
	logic media_wr_fifo_pop;
	wire media_wr_fifo_full = (media_wr_fifo_count == MEDIA_WR_FIFO_DEPTH[MEDIA_WR_FIFO_AW:0]);
	wire media_wr_fifo_empty = (media_wr_fifo_count == '0);
	wire [24:0] media_wr_fifo_head_addr = media_wr_fifo[media_wr_fifo_rd_ptr][32:8];
	wire [7:0] media_wr_fifo_head_data = media_wr_fifo[media_wr_fifo_rd_ptr][7:0];
	logic image_verified;
	logic verify_active;
	logic verify_failed;
	logic [24:0] verify_addr;
	logic [24:0] verify_size_latched;
	logic [31:0] verify_expected_crc_latched;
	logic [31:0] verify_crc_state;

	logic ctl_req;
	logic ctl_write;
	logic [24:0] ctl_addr;
	logic [15:0] ctl_din;
	logic [63:0] ctl_dout;
	logic ctl_ready;
	logic ctl_busy;
	logic ctl_initialized;

	// Clients 0..2 are the three Z80s. A miss on one of those holds its CPU
	// in wait states, which slows the emulated machine directly, while the
	// sprite renderer, sample and PROM clients have a whole frame of slack
	// and complete their pass many times over within one. Serve the CPUs
	// first, and round-robin only among the rest, so the renderer can still
	// never be starved indefinitely (a CPU that hits its cache stops
	// requesting, which it does for most of a frame).
	function automatic logic [3:0] pick_client
	(
		input logic [6:0] miss,
		input logic [2:0] start
	);
		integer n;
		integer candidate;
		begin
			pick_client = 4'hf;
			for (n = 0; n < 3; n = n + 1)
				if (pick_client == 4'hf && miss[n])
					pick_client = n[3:0];
			candidate = (start < 3'd3) ? 32'd3 : {29'd0, start};
			for (n = 0; n < 4; n = n + 1) begin
				if (pick_client == 4'hf && miss[candidate])
					pick_client = candidate[3:0];
				if (candidate == 6)
					candidate = 3;
				else
					candidate = candidate + 1;
			end
		end
	endfunction

	assign client_abs[0] = main_abs;
	assign client_abs[1] = sound_abs;
	assign client_abs[2] = pcm_abs;
	assign client_abs[3] = gfx1_abs;
	assign client_abs[4] = gfx2_abs;
	assign client_abs[5] = sample_abs;
	assign client_abs[6] = prom_abs;

	logic [6:0] client_ready;
	logic [7:0] client_q [0:6];

	always_comb begin
		for (int c = 0; c < 7; c++) begin
			cache_hit_way[c] = 2'd0;
			for (int w = 0; w < CACHE_WAYS; w++) begin
				cache_hit[c][w] = cache_valid_way[w][c] &&
					(cache_tag[c][w] == client_abs[c][24:3]);
				if (cache_hit[c][w])
					cache_hit_way[c] = w[1:0];
			end
			client_ready[c] = |cache_hit[c];
			client_q[c] = cache_byte(cache_data[c][cache_hit_way[c]],
			                         client_abs[c][2:0]);
		end

		main_ready   = client_ready[0];
		sound_ready  = client_ready[1];
		pcm_ready    = client_ready[2];
		gfx1_ready   = client_ready[3];
		gfx2_ready   = client_ready[4];
		sample_ready = client_ready[5];
		prom_ready   = client_ready[6];

		main_q   = client_q[0];
		sound_q  = client_q[1];
		pcm_q    = client_q[2];
		gfx1_q   = client_q[3];
		gfx2_q   = client_q[4];
		gfx1_line_q = cache_data[3][cache_hit_way[3]];
		gfx2_line_q = cache_data[4][cache_hit_way[4]];
		sample_q = client_q[5];
		prom_q   = client_q[6];

		// CPU clients only request on a genuine ROM read cycle (W21.1); the
		// hit path and *_ready stay unconditional so wait_n is unaffected.
		cache_miss[0] = runtime_enable && main_req && !main_ready;
		cache_miss[1] = runtime_enable && sound_req && !sound_ready;
		cache_miss[2] = runtime_enable && pcm_req && !pcm_ready;
		cache_miss[3] = runtime_enable && !gfx1_ready;
		cache_miss[4] = runtime_enable && !gfx2_ready;
		cache_miss[5] = runtime_enable && !sample_ready;
		cache_miss[6] = runtime_enable && !prom_ready;
		selected_client = pick_client(cache_miss, round_robin);
	end

	// Back-pressure on FIFO occupancy, not on instantaneous SDRAM busy
	// state -- see the FIFO comment above for why the old definition
	// dropped bytes on real hardware.
	assign ioctl_wait = !ctl_initialized ||
		(media_wr_fifo_count >= MEDIA_WR_FIFO_WATERMARK[MEDIA_WR_FIFO_AW:0]);
	assign media_write_busy = !ctl_initialized || !media_wr_fifo_empty ||
		write_pair_valid || (transaction_active && active_client == CLIENT_WRITE);
	assign media_wr_fifo_push = media_wr_valid && !media_wr_fifo_full;
	logic bytes_dropped;
	logic download_active_d;
	assign media_bytes_dropped = bytes_dropped;
	assign media_wr_fifo_pop = !transaction_active && ctl_initialized &&
		!ctl_busy && !media_wr_fifo_empty;
	assign media_ready = ctl_initialized && image_verified;
	assign media_initialized = ctl_initialized;
	assign media_verify_active = verify_active;
	assign media_verify_failed = verify_failed;
	assign media_verify_crc = ~verify_crc_state;
	assign media_busy = ctl_busy || transaction_active || verify_active;
	assign debug_cache_miss = cache_miss;
	assign debug_transaction_active = transaction_active;

	// The controller now returns an eight-byte line per read, so the image
	// CRC consumes the whole line in address order. The tail of an image
	// whose size is not a multiple of eight contributes only its real bytes,
	// so the running chain is tapped at the byte count still inside the
	// image rather than always at eight.
	wire [31:0] verify_crc_chain [0:8];
	assign verify_crc_chain[0] = verify_crc_state;
	generate
		genvar vb;
		for (vb = 0; vb < 8; vb = vb + 1) begin : g_verify_crc
			assign verify_crc_chain[vb + 1] =
				media_crc32_byte(verify_crc_chain[vb], ctl_dout[vb * 8 +: 8]);
		end
	endgenerate
	wire [24:0] verify_remaining = verify_size_latched - verify_addr;
	wire [3:0] verify_bytes = (verify_remaining >= 25'd8)
		? 4'd8 : verify_remaining[3:0];
	wire [31:0] verify_crc_word = verify_crc_chain[verify_bytes];

	suna8_sdram_controller u_controller
	(
		.clk(clk),
		.reset(reset),
		.SDRAM_DQ(SDRAM_DQ),
		.SDRAM_A(SDRAM_A),
		.SDRAM_BA(SDRAM_BA),
		.SDRAM_CLK(SDRAM_CLK),
		.SDRAM_CKE(SDRAM_CKE),
		.SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCS(SDRAM_nCS),
		.req(ctl_req),
		.write(ctl_write),
		.addr(ctl_addr),
		.din(ctl_din),
		.dout(ctl_dout),
		.ready(ctl_ready),
		.busy(ctl_busy),
		.initialized(ctl_initialized)
	);

	always_ff @(posedge clk) begin
		if (reset) begin
			for (int w = 0; w < CACHE_WAYS; w++) cache_valid_way[w] <= 7'd0;
			for (int c = 0; c < 7; c++) cache_way_next[c] <= 2'd0;
			bytes_dropped     <= 1'b0;
			download_active_d <= 1'b0;
			round_robin       <= 3'd3;
			active_client     <= 4'hf;
			pending_tag       <= 22'd0;
			transaction_active <= 1'b0;
			write_pair_valid   <= 1'b0;
			write_pair_addr    <= 25'd0;
			write_pair_low     <= 8'd0;
			image_verified     <= 1'b0;
			verify_active      <= 1'b0;
			verify_failed      <= 1'b0;
			verify_addr        <= 25'd0;
			verify_size_latched <= 25'd0;
			verify_expected_crc_latched <= 32'd0;
			verify_crc_state   <= 32'hffffffff;
			ctl_req           <= 1'b0;
			ctl_write         <= 1'b0;
			ctl_addr          <= 25'd0;
			ctl_din           <= 16'd0;
			media_wr_fifo_wr_ptr <= '0;
			media_wr_fifo_rd_ptr <= '0;
			media_wr_fifo_count  <= '0;
		end else begin
			ctl_req <= 1'b0;

			// FIFO push/pop are independent of every other state below:
			// pushing must never be gated on SDRAM readiness (that is
			// exactly the coupling that dropped bytes), and popping must
			// never be skipped just because a cycle also happens to push.
			if (media_wr_fifo_push) begin
				media_wr_fifo[media_wr_fifo_wr_ptr] <= {media_wr_addr, media_wr_data};
				media_wr_fifo_wr_ptr <= media_wr_fifo_wr_ptr + 1'b1;
			end
			if (media_wr_fifo_pop)
				media_wr_fifo_rd_ptr <= media_wr_fifo_rd_ptr + 1'b1;
			case ({media_wr_fifo_push, media_wr_fifo_pop})
				2'b10:   media_wr_fifo_count <= media_wr_fifo_count + 1'b1;
				2'b01:   media_wr_fifo_count <= media_wr_fifo_count - 1'b1;
				default: media_wr_fifo_count <= media_wr_fifo_count;
			endcase

			// A new host transfer invalidates every prior image verdict before
			// its first byte is accepted. The SDRAM controller itself remains
			// initialized so Main can stream the replacement image immediately.
			download_active_d <= download_active;
			if (download_active) begin
				image_verified <= 1'b0;
				verify_active <= 1'b0;
				verify_failed <= 1'b0;
				verify_addr <= 25'd0;
				verify_crc_state <= 32'hffffffff;
				for (int w = 0; w < CACHE_WAYS; w++) cache_valid_way[w] <= 7'd0;
				for (int c = 0; c < 7; c++) cache_way_next[c] <= 2'd0;
				if (!download_active_d)
					bytes_dropped <= 1'b0;
			end
			// A byte the host pushed while the FIFO was full is gone for good
			// (W21.3); remember it so the boot diagnostic can say so.
			if (media_wr_valid && media_wr_fifo_full)
				bytes_dropped <= 1'b1;
			// After the transfer ends and the FIFO has drained, a half-written
			// pair can never complete. Without this it held media_write_busy
			// high forever and the machine never left reset (W21.3).
			if (!download_active && media_wr_fifo_empty && write_pair_valid &&
			    !transaction_active) begin
				write_pair_valid <= 1'b0;
				bytes_dropped <= 1'b1;
			end

			if (ctl_ready && transaction_active) begin
				transaction_active <= 1'b0;
				if ((active_client == CLIENT_VERIFY) && verify_active &&
				    !download_active) begin
					verify_crc_state <= verify_crc_word;
					if (verify_addr + 25'd8 >= verify_size_latched) begin
						verify_active <= 1'b0;
						if ((~verify_crc_word) == verify_expected_crc_latched)
							image_verified <= 1'b1;
						else
							verify_failed <= 1'b1;
					end else begin
						verify_addr <= verify_addr + 25'd8;
					end
				end else if (active_client < CLIENT_WRITE && !download_active) begin
					// A fill granted just before ioctl_download rose must not
					// re-validate a way after the invalidate above (W21.5).
					cache_data[active_client[2:0]][cache_way_next[active_client[2:0]]] <= ctl_dout;
					cache_tag[active_client[2:0]][cache_way_next[active_client[2:0]]] <= pending_tag;
					cache_valid_way[cache_way_next[active_client[2:0]]][active_client[2:0]] <= 1'b1;
					cache_way_next[active_client[2:0]] <=
						cache_way_next[active_client[2:0]] + 2'd1;
				end
			end

			if (verify_enable && !download_active && !verify_active &&
			    !image_verified && !verify_failed && !transaction_active &&
			    ctl_initialized && !ctl_busy) begin
				// Every shipped image is a multiple of 8 bytes, so the line-tail
				// CRC path is unexercised; refuse anything else rather than run
				// untested logic silently (W21.6).
				if ((verify_size == 25'd0) || (verify_size[2:0] != 3'd0)) begin
					verify_failed <= 1'b1;
				end else begin
					verify_active <= 1'b1;
					verify_addr <= 25'd0;
					verify_size_latched <= verify_size;
					verify_expected_crc_latched <= verify_expected_crc;
					verify_crc_state <= 32'hffffffff;
					for (int w = 0; w < CACHE_WAYS; w++) cache_valid_way[w] <= 7'd0;
					for (int c = 0; c < 7; c++) cache_way_next[c] <= 2'd0;
				end
			end

			if (!transaction_active && ctl_initialized && !ctl_busy) begin
				if (!media_wr_fifo_empty) begin
					// MRA parts are even-aligned and even-sized. Buffer the low
					// byte, then issue one unmasked 16-bit SDRAM write when the
					// matching high byte arrives. Independent byte masks are not
					// electrically valid on MiSTer's 128 MB module. Bytes are
					// drained from the elastic FIFO (media_wr_fifo_pop, above)
					// rather than read live off media_wr_valid/_addr/_data, so
					// this runs at the SDRAM's own pace regardless of ioctl
					// arrival timing.
					if (!media_wr_fifo_head_addr[0]) begin
						write_pair_valid <= 1'b1;
						write_pair_addr <= media_wr_fifo_head_addr;
						write_pair_low <= media_wr_fifo_head_data;
						for (int w = 0; w < CACHE_WAYS; w++) cache_valid_way[w] <= 7'd0;
						for (int c = 0; c < 7; c++) cache_way_next[c] <= 2'd0;
					end else if (write_pair_valid &&
						write_pair_addr[24:1] == media_wr_fifo_head_addr[24:1]) begin
						ctl_req <= 1'b1;
						ctl_write <= 1'b1;
						ctl_addr <= write_pair_addr;
						ctl_din <= {media_wr_fifo_head_data, write_pair_low};
						active_client <= CLIENT_WRITE;
						transaction_active <= 1'b1;
						write_pair_valid <= 1'b0;
						for (int w = 0; w < CACHE_WAYS; w++) cache_valid_way[w] <= 7'd0;
						for (int c = 0; c < 7; c++) cache_way_next[c] <= 2'd0;
					end else if (write_pair_valid) begin
						// Odd byte that does not pair with the buffered even
						// byte: both are lost. Record it; the CRC readback
						// will fail and the diagnostic will name the cause.
						write_pair_valid <= 1'b0;
						bytes_dropped <= 1'b1;
					end
				end else if (verify_active) begin
					ctl_req <= 1'b1;
					ctl_write <= 1'b0;
					ctl_addr <= verify_addr;
					active_client <= CLIENT_VERIFY;
					transaction_active <= 1'b1;
				end else if (selected_client != 4'hf) begin
					ctl_req <= 1'b1;
					ctl_write <= 1'b0;
					active_client <= selected_client;
					transaction_active <= 1'b1;
					case (selected_client)
						// The controller aligns a read burst to its own
						// eight-byte boundary, so hand it the line address
						// and tag the cache with the same line.
						4'd0: begin ctl_addr <= {main_abs[24:3], 3'b000};   pending_tag <= main_abs[24:3]; end
						4'd1: begin ctl_addr <= {sound_abs[24:3], 3'b000};  pending_tag <= sound_abs[24:3]; end
						4'd2: begin ctl_addr <= {pcm_abs[24:3], 3'b000};    pending_tag <= pcm_abs[24:3]; end
						4'd3: begin ctl_addr <= {gfx1_abs[24:3], 3'b000};   pending_tag <= gfx1_abs[24:3]; end
						4'd4: begin ctl_addr <= {gfx2_abs[24:3], 3'b000};   pending_tag <= gfx2_abs[24:3]; end
						4'd5: begin ctl_addr <= {sample_abs[24:3], 3'b000}; pending_tag <= sample_abs[24:3]; end
						default: begin ctl_addr <= {prom_abs[24:3], 3'b000}; pending_tag <= prom_abs[24:3]; end
					endcase
					// round_robin only orders the non-CPU clients (3..6);
					// a CPU grant leaves their rotation where it was so a
					// busy CPU cannot repeatedly reset the renderer's turn.
					if (selected_client >= 4'd3) begin
						if (selected_client == 4'd6)
							round_robin <= 3'd3;
						else
							round_robin <= selected_client[2:0] + 3'd1;
					end
				end
			end
		end
	end

endmodule
