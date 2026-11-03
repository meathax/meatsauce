// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - Board Top Level
//
//  Connects the master and slave Z80, the video system, the SDRAM controller (program,
//  sound and tile ROMs), block RAM (VRAM 128 KB, work RAM, colour RAM, EEPROM) and the
//  80186 sound board (rtl/audio/leland_sound.sv).
//
//  SDRAM layout (byte addresses after the 16-byte header; see leland_board_pkg.sv):
//    0x000000 master Z80 ROM    0x100000 slave Z80 ROM    0x300000 80186 sound ROM
//    0x400000 bg_gfx tile ROM   0x600000 bg_prom PROM     (plus derived repack areas)
//============================================================================

import leland_board_pkg::*;

module leland_board #(
	// Passed to the internal sdram controller (see rtl/mem/sdram.sv): 1 is required on
	// hardware; simulation overrides it to 0 to avoid Altera's simulation libraries.
	parameter bit USE_ALTDDIO = 1'b1,

	// ioctl_download must stay low this long before loading counts as finished (250 ms at
	// the selected clk_sys; simulation overrides it). One <rom index="0"> tag does not guarantee one
	// download session (address 0/1 were seen written twice), so "done" is a quiet
	// period rather than a session count.
	parameter int unsigned DL_SETTLE_CYCLES = 12_000_000,

	// Clock selection is board-local. 1 is the nominal-root diagnostic; 2 is the
	// standard MiSTer 630 MHz / 11 PLL root used by the production top.
	parameter int unsigned TARGET_CLOCK_PROFILE = 0,
	// CPU pacing and Ataxx Z80 recovery remain legacy by default. These board-level
	// selectors are passed explicitly to their consumers so generated diagnostics
	// must select the board profile rather than relying on child-module defaults.
	parameter integer CPU_PACING_PROFILE = 0,
	parameter integer Z80_RECOVERY_PROFILE = 0,
	// Opt-in audited WSF route math; other variants retain their legacy mixer.
	parameter integer WSF_MIXER_PROFILE = 0,
	// Dedicated game builds can prune unused board variants. Generic users
	// retain header selection; the Asylum top selects its existing table entry.
	parameter bit ASYLUM_RENDER_SNAPSHOT = 0,
	parameter integer FIXED_GAME_ID = -1
)
(
	input         clk_sys,   // production top: 630 MHz / 11
	input         clk_sdram, // phase-shifted clk_sys, drives SDRAM_CLK
	input         clk_cap,   // clk_sys-rate PLL output phased to the centre of the SDRAM read-data window
	input         reset,      // CPU/game reset (includes ioctl_download)
	input         sdram_init, // SDRAM hardware reset only (~pll_locked | RESET)

	// ROM loading from HPS
	input         ioctl_download,
	input  [15:0] ioctl_index,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input   [7:0] ioctl_data,
	output        ioctl_wait, // stall HPS while SDRAM write is in progress

	// EEPROM save file (MRA <nvram index="4">). The restore stream is hps_io's own
	// ioctl_* (nvl_*), not the ones above: leland_ddr_loader replaces those while it
	// replays the ROM from DDR3, which is exactly when the save file arrives.
	input         nvl_download,
	input  [15:0] nvl_index,
	input         nvl_wr,
	input  [26:0] nvl_addr,
	input   [7:0] nvl_data,
	input   [7:0] nv_rd_addr,
	output  [7:0] nv_rd_data,
	output        nv_dirty,
	input         nv_dirty_clr,

	// SDRAM chip pins (pass-through to top level)
	inout  [15:0] SDRAM_DQ,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output        SDRAM_nCS,
	output        SDRAM_nRAS,
	output        SDRAM_nCAS,
	output        SDRAM_nWE,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,

	// Video
	output        ce_pix,
	output        HBlank,
	output        HSync,
	output        VBlank,
	output        VSync,
	output [23:0] rgb,
 // Optional Asylum render snapshot DDR client (64-bit word addresses).
 output [28:0] snapshot_ddr_addr, output [63:0] snapshot_ddr_din,
 output snapshot_ddr_rd, output snapshot_ddr_we,
 input snapshot_ddr_busy, input [63:0] snapshot_ddr_dout,
 input snapshot_ddr_ready, input snapshot_transport_fault, input snapshot_init,

	// Player controls (digital)
	input   [3:0] p1_btn, p2_btn, p3_btn,
	// Wheel: free-running mod-256 virtual dial (stick + d-pad + spinner combined by
	// steering_input.sv); leland_master turns it into MAME's dial_compute_value() encoding.
	input   [7:0] p1_wheel, p2_wheel, p3_wheel,
	// Pedal: raw 8-bit value (0 = released, 255 = full), read directly as MAME's
	// IPT_PEDAL AN0/AN1/AN2 do.
	input   [7:0] p1_pedal, p2_pedal, p3_pedal,

	// Ataxx trackballs (free-running mod-256 positions, see trackball_input.sv)
	input   [7:0] p1_tb_x, p1_tb_y, p2_tb_x, p2_tb_y,

	// 4-player digital joystick, used only when the active game's
	// input_scheme is JOY4_DIGITAL (pigout) -- unconsumed for WHEELS3_
	// PEDALS3 games. Bit layout: [0]=right [1]=left [2]=down [3]=up
	// [4]=btn1 [5]=btn2 [6]=start [7]=coin (standard MiSTer joystick
	// vector convention).
	input   [7:0] p1_joy, p2_joy, p3_joy, p4_joy,

	// OSD options
	input         service,

	// Header game id, so the top level can order the buttons per game
	output  [7:0] game_id,

	// 4-bit-per-channel palette (Ataxx/WSF boards), for the CRT retimer
	output        ax_video,

	// Audio (leland_dac_mixer mono output, via leland_sound)
	output signed [15:0] audio_out
);

//------------------------------------------------------------------
// Clock enables. Pixel cadence is always an integer divide-by-8 CE. Profile 0
// retains integer CPU enables for unit-level diagnostics; production profile 2
// supplies rational one-edge enables from the qualified 630 MHz / 11 plan.
//------------------------------------------------------------------
wire CE_6M;
wire CE_8M;
wire CE_4M;
wire ce_release_boundary;
generate
if (TARGET_CLOCK_PROFILE == 0) begin : g_legacy_clock_profile
	reg [2:0] legacy_z80_count = 3'd0;
	reg [2:0] legacy_i186_count = 3'd0;
	reg [2:0] legacy_pixel_phase = 3'd0;
	reg       legacy_pixel_ce = 1'b0;

	assign CE_6M = (legacy_z80_count == 3'd0);
	assign CE_8M = (legacy_i186_count == 3'd0);
	assign CE_4M = 1'b0;
	// Preserve the original combinational raw-counter release sample in profile 0.
	assign ce_release_boundary = (legacy_z80_count == 3'd0);
	always @(posedge clk_sys) begin
		legacy_z80_count <= (legacy_z80_count == 3'd7) ? 3'd0 : legacy_z80_count + 1'd1;
		legacy_i186_count <= (legacy_i186_count == 3'd5) ? 3'd0 : legacy_i186_count + 1'd1;
		legacy_pixel_phase <= legacy_pixel_phase + 1'b1;
		legacy_pixel_ce <= (legacy_pixel_phase == 3'd7);
	end
	assign ce_pix = legacy_pixel_ce;
end else if (TARGET_CLOCK_PROFILE == 1 || TARGET_CLOCK_PROFILE == 2) begin : g_target_clock_profile
	leland_target_enables #(.RATE_PROFILE(TARGET_CLOCK_PROFILE == 2)) target_clock_enables (
		.clk_sys(clk_sys),
		.ce_pixel(ce_pix),
		.ce_z80(CE_6M),
		.ce_186(CE_8M),
		.ce_4m(CE_4M)
	);
	// Target CE is registered by the accumulator and consumed on the next root edge.
	assign ce_release_boundary = CE_6M;
end else begin : g_invalid_clock_profile
	assign CE_6M = 1'b0;
	assign CE_8M = 1'b0;
	assign CE_4M = 1'b0;
	assign ce_release_boundary = 1'b0;
	assign ce_pix = 1'b0;
	initial $error("Unsupported TARGET_CLOCK_PROFILE");
end
endgenerate

localparam integer TARGET_ROOT_HZ_NUMERATOR =
	TARGET_CLOCK_PROFILE == 2 ? 630_000_000 :
	TARGET_CLOCK_PROFILE == 1 ? 57_272_724 : 48_000_000;
localparam integer TARGET_ROOT_HZ_DENOMINATOR = TARGET_CLOCK_PROFILE == 2 ? 11 : 1;

//------------------------------------------------------------------
// SDRAM controller: one single-port controller plus an external arbiter (wr on top,
// reads round-robin). The controller owns periodic refresh and a JEDEC-sequenced init.
//------------------------------------------------------------------
reg         sdram_ready; // sticky "init genuinely completed" -- see always block below

// Write port (ioctl): always a full 16-bit word (sdram_wr_data = even/low byte,
// sdram_wr_data_hi = odd/high byte). DQM does not select byte lanes on this board, so
// a masked byte write would corrupt the other lane. sdram_wr_addr is the even
// (word-aligned) address of the pair.
wire        sdram_wr_req;
reg         sdram_wr_ack;
wire [24:0] sdram_wr_addr;
wire  [7:0] sdram_wr_data;
wire  [7:0] sdram_wr_data_hi;

// Read port 2: leland_video's tile gfx/PROM fetch. sdram_rd2_req/addr feed the arbiter
// and are muxed (near the gfx-repack FSM) between leland_video's request and the boot-
// time repack and EEPROM FSMs, which are never active at the same time as it.
wire        sdram_rd2_req;
wire [24:0] sdram_rd2_addr;
wire        sdram_rd2_req_v;
wire [24:0] sdram_rd2_addr_v;
reg         sdram_rd2_ack;
reg   [7:0] sdram_rd2_data;
reg  [15:0] sdram_rd2_data16;    // burst word 0, see leland_video.sv
reg  [15:0] sdram_rd2_data16_w2;   // burst word 2 (Ataxx)
reg  [15:0] sdram_rd2_data16_w3;   // burst word 3 (Ataxx repack)
reg  [15:0] sdram_rd2_data16_hi; // burst word 1
wire        rd2_fetch_busy; // whole-tile-burst-in-progress, see leland_video.sv's fetch_busy comment
wire  [3:0] rd2_rbuf_count; // ring-buffer occupancy, see leland_video.sv's rbuf_count_out comment

// Read port 0 (master Z80)
wire        sdram_rd0_req;
reg         sdram_rd0_ack;
wire [24:0] sdram_rd0_addr;
reg   [7:0] sdram_rd0_data;

// Read port 1 (slave Z80)
wire        sdram_rd1_req;
reg         sdram_rd1_ack;
wire [24:0] sdram_rd1_addr;
reg   [7:0] sdram_rd1_data;

// Read port 3: sound CPU ROM, via leland_sound's byte-wide rom_req/rom_addr/rom_data/
// rom_stall port, built like rd0/rd1.
wire        sdram_rd3_req;
reg         sdram_rd3_ack;
wire [24:0] sdram_rd3_addr;
reg   [7:0] sdram_rd3_data;

// SDRAM chip-side signals (16-bit DQ, matches the physical SDRAM_DQ pin)
wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
wire  [1:0] sd_ba;
wire [12:0] sd_a;
wire  [1:0] sd_dqm;
wire [15:0] sd_dq_out;
wire        sd_dq_oe;
// Read data is registered in the pad's input register by its own PLL phase, centred in the
// data window STA derives from the board-level SDRAM budget. The controller loads it one
// core edge later (READ_CAP_EXTRA), so the beat it captures is unchanged.
reg  [15:0] sd_dq_q;
always @(posedge clk_cap) sd_dq_q <= SDRAM_DQ;
wire [15:0] sd_dq_in = sd_dq_q;
assign SDRAM_DQ = sd_dq_oe ? sd_dq_out : 16'bz;

assign SDRAM_CKE  = sd_cke;
assign SDRAM_nCS  = sd_cs_n;
assign SDRAM_nRAS = sd_ras_n;
assign SDRAM_nCAS = sd_cas_n;
assign SDRAM_nWE  = sd_we_n;
assign SDRAM_BA   = sd_ba;
assign SDRAM_A    = sd_a;
assign {SDRAM_DQMH, SDRAM_DQML} = sd_dqm;

// Single-port module's own client interface
// (* keep *) preserves these names through synthesis for SignalTap captures.
(* keep *) wire        sd_ready;
(* keep *) wire        sd_req_done;
(* keep *) wire        sd_req_hit;
(* keep *) wire  [7:0] sd_dout;
(* keep *) wire [15:0] sd_dout16; // full captured word, see sdram.sv's dout16
// Burst-safe views of the above: sd_dout_b0 / sd_burst_words are what the arbiter
// latches into each channel's data register, so raising BURST_LEN cannot corrupt a
// client still on the legacy path.
(* keep *) wire  [7:0] sd_dout_b0;
(* keep *) wire [7:0][15:0] sd_burst_words;

localparam CH_WR = 3'd0, CH_RD2 = 3'd1, CH_RD0 = 3'd2, CH_RD1 = 3'd3, CH_RD3 = 3'd4;

// Arbitration: wr has absolute priority and the four read channels are served round-
// robin (below), all gated by !in_flight.
//
// in_flight fences the level-sensitive SDRAM controller, which accepts whenever
// rd||we is high. A client's req is still high on the cycle its transaction completes
// (the ack is registered), so without the gate the controller accepted the same
// request twice and every read channel ran one transaction behind (each address
// paired with the previous byte's data). Writes hid it because a duplicated write
// rewrites the same byte. So no request is presented from the moment one is accepted
// until the granted client has dropped its req; every client deasserts req for at
// least one cycle after its ack.
(* keep *) reg        in_flight;   // transaction accepted, client hasn't dropped req yet
(* keep *) reg        done_seen;   // its req_done has fired (completion latched)
(* keep *) reg  [2:0] issued_ch;

//------------------------------------------------------------------
// Round-robin read arbitration. With fixed priority the 80186 sound ROM channel (rd3)
// starved under gameplay load, and a bespoke aging counter per channel does not scale.
// wr keeps absolute priority (loading needs its writes undelayed). rr_last is the
// channel granted last; the next grant scans from rr_last+1 and wraps, so no channel
// is skipped for more than 3 consecutive read grants.
localparam RR_RD0 = 2'd0, RR_RD1 = 2'd1, RR_RD2 = 2'd2, RR_RD3 = 2'd3;
reg [1:0] rr_last;

wire [3:0] rr_req = {sdram_rd3_req, sdram_rd2_req, sdram_rd1_req, sdram_rd0_req}; // bit N = channel N's req

function automatic [1:0] rr_pick(input [3:0] req, input [1:0] last);
	reg [1:0] c1, c2, c3;
	begin
		c1 = last + 2'd1;
		c2 = last + 2'd2;
		c3 = last + 2'd3;
		if      (req[c1]) rr_pick = c1;
		else if (req[c2]) rr_pick = c2;
		else if (req[c3]) rr_pick = c3;
		else if (req[last]) rr_pick = last;
		else rr_pick = last; // no request pending at all -- don't-care, sel_* below all read 0
	end
endfunction

// rd2 urgency escalation: round-robin plus one bounded exception for rd2 (video), the
// only channel that needs it. rd2 preempts round-robin only when its current tile
// fetch has waited at least URGENT_THRESH cycles AND the ring buffer has fallen to
// RD2_LOW_WATER or fewer of its 8 entries, i.e. it is close to running dry. A fuller
// buffer rides plain round-robin, which leaves those slots to rd0/rd1/rd3. Escalating
// every channel, or rd2 on wait time alone, raised CPU and sound latency without
// helping the video.
//
// rd2_wait_cnt counts while rd2_fetch_busy (a whole tile burst in progress) rather
// than a plain req&&!ack: leland_video drops req for one cycle between the sub-requests
// of a tile, which would reset the count at every boundary.
localparam URGENT_THRESH   = 8'd32;
// Escalating earlier (LOW_WATER=2) still lowered rd0/rd1/rd3 throughput in gameplay (a
// HUD update visibly lagged a nitro pickup) while rd2's own latency stayed in budget.
localparam RD2_LOW_WATER   = 4'd1; // buffer depth is 8 (RBUF_N in leland_video.sv); escalate only at <=1 of 8

reg [7:0] rd2_wait_cnt;
always @(posedge clk_sys) begin
	if (sdram_init) rd2_wait_cnt <= 8'd0;
	else rd2_wait_cnt <= rd2_fetch_busy ? ((rd2_wait_cnt == 8'hFF) ? rd2_wait_cnt : rd2_wait_cnt + 8'd1) : 8'd0;
end

wire       rd2_urgent  = sdram_rd2_req && (rd2_wait_cnt >= URGENT_THRESH) && (rd2_rbuf_count <= RD2_LOW_WATER);
wire [1:0] rr_grant_ch = rd2_urgent ? RR_RD2 : rr_pick(rr_req, rr_last);

wire sel_wr  = !in_flight && sdram_wr_req;
wire sel_rd0 = !in_flight && !sel_wr && sdram_rd0_req && (rr_grant_ch == RR_RD0);
wire sel_rd1 = !in_flight && !sel_wr && sdram_rd1_req && (rr_grant_ch == RR_RD1);
wire sel_rd2 = !in_flight && !sel_wr && sdram_rd2_req && (rr_grant_ch == RR_RD2);
wire sel_rd3 = !in_flight && !sel_wr && sdram_rd3_req && (rr_grant_ch == RR_RD3);

// Each client is pinned to one SDRAM bank (leland_board_pkg sdram_addr_to_bank /
// sdram_bank_base). sd_addr_rel is the byte offset inside that bank, sd_bank the bank:
//   rd0 master Z80  -> bank 0 (ADDR_MASTER_BASE)   rd1 slave Z80 -> bank 1 (ADDR_SLAVE_BASE)
//   rd3 80186 sound -> bank 2 (ADDR_SOUND_BASE)    rd2 video gfx -> bank 3 (ADDR_GFX_BASE)
//   wr  (ioctl + repack) -> decoded from sdram_wr_addr
wire [1:0]  wr_bank    = sdram_addr_to_bank({2'b0, sdram_wr_addr});
wire [22:0] wr_rel     = sdram_wr_addr[22:0] - sdram_bank_base({2'b0, sdram_wr_addr});

(* keep *) wire  [1:0] sd_bank     = sel_wr  ? wr_bank :
                                      sel_rd0 ? 2'd0 :
                                      sel_rd1 ? 2'd1 :
                                      sel_rd3 ? 2'd2 :
                                                2'd3;   // sel_rd2
(* keep *) wire [22:0] sd_addr_rel = sel_wr  ? wr_rel :
                       sel_rd0 ? sdram_rd0_addr[22:0] :                           // MASTER_BASE=0
                       sel_rd1 ? (sdram_rd1_addr[22:0] - ADDR_SLAVE_BASE[22:0]) :
                       sel_rd2 ? (sdram_rd2_addr[22:0] - ADDR_GFX_BASE[22:0])   :
                                 (sdram_rd3_addr[22:0] - ADDR_SOUND_BASE[22:0]);
(* keep *) wire  [7:0] sd_din    = sdram_wr_data;
(* keep *) wire  [7:0] sd_din_hi = sdram_wr_data_hi;
// Every write is a full-word write; the byte-masked `we` path is unused.
(* keep *) wire        sd_we      = 1'b0;
(* keep *) wire        sd_we_word = sel_wr;
(* keep *) wire        sd_rd      = sel_rd2 | sel_rd0 | sel_rd1 | sel_rd3;

// Level of the granted channel's req line: in_flight releases only once it drops, so
// the controller never sees a request whose ack is still propagating.
wire issued_req_level = (issued_ch == CH_WR)  ? sdram_wr_req  :
                        (issued_ch == CH_RD2) ? sdram_rd2_req :
                        (issued_ch == CH_RD0) ? sdram_rd0_req :
                        (issued_ch == CH_RD1) ? sdram_rd1_req :
                                                sdram_rd3_req;

always @(posedge clk_sys) begin
	sdram_wr_ack  <= 1'b0;
	sdram_rd2_ack <= 1'b0;
	sdram_rd0_ack <= 1'b0;
	sdram_rd1_ack <= 1'b0;
	sdram_rd3_ack <= 1'b0;

	if (sdram_init) begin
		sdram_ready <= 1'b0;
		in_flight   <= 1'b0;
		done_seen   <= 1'b0;
		rr_last     <= RR_RD0;
	end else begin
		// Sticky "init completed at least once": sd_ready toggles per transaction after init,
		// but reset gating and ioctl_wait need the sticky form.
		if (sd_ready) sdram_ready <= 1'b1;

		// Accept: latch the granted channel on the cycle the controller is idle and a
		// request is presented. sel_* are gated by !in_flight, so issued_ch cannot be
		// overwritten mid-flight.
		if (sd_ready && (sd_rd || sd_we_word)) begin
			issued_ch <= sel_wr ? CH_WR : sel_rd2 ? CH_RD2 : sel_rd0 ? CH_RD0 : sel_rd1 ? CH_RD1 : CH_RD3;
			in_flight <= 1'b1;
			done_seen <= 1'b0;
				// Only reads rotate the round-robin pointer; a write does not use up a read
				// channel's turn.
			if (!sel_wr) rr_last <= rr_grant_ch;
		end

		// Completion: sd_req_done tells a client transaction finishing from an internal
		// refresh finishing; with the in_flight gate it fires once per accepted transaction.
		if (sd_req_done) begin
			done_seen <= 1'b1;
			case (issued_ch)
				CH_WR:  sdram_wr_ack  <= 1'b1;
	CH_RD2: begin sdram_rd2_data <= sd_dout_b0; sdram_rd2_data16 <= sd_burst_words[0]; sdram_rd2_data16_hi <= sd_burst_words[1]; sdram_rd2_data16_w2 <= sd_burst_words[2]; sdram_rd2_data16_w3 <= sd_burst_words[3]; sdram_rd2_ack <= 1'b1; end
				CH_RD0: begin sdram_rd0_data <= sd_dout_b0; sdram_rd0_ack <= 1'b1; end
				CH_RD1: begin sdram_rd1_data <= sd_dout_b0; sdram_rd1_ack <= 1'b1; end
				CH_RD3: begin sdram_rd3_data <= sd_dout_b0; sdram_rd3_ack <= 1'b1; end
			endcase
		end

		// Release once completion has fired and the client has dropped its req (proof it
		// consumed the ack); only then may the mux present the next request.
		if (in_flight && (done_seen || sd_req_done) && !issued_req_level) begin
			in_flight <= 1'b0;
			done_seen <= 1'b0;
		end
	end
end

// sdram_banked: open-row multi-bank controller. bank_sel pins each client to its own
// physical bank so interleaving between clients does not thrash open rows. CAS_LAT=3
// is the proven value for this design. BURST_LEN=4 is shared by every channel (single-
// word clients read sd_dout_b0 / sd_burst_words[0], which is correct for any burst
// length); only rd2's GFXROW fetch uses the second word.
sdram_banked #(
	.CLK_MHZ(48),
	.USE_RATIONAL_CLOCK(TARGET_CLOCK_PROFILE != 0),
	.CLK_HZ_NUMERATOR(TARGET_ROOT_HZ_NUMERATOR),
	.CLK_HZ_DENOMINATOR(TARGET_ROOT_HZ_DENOMINATOR),
	.CAS_LAT(3),
	.READ_CAP_EXTRA(1),
	.BURST_LEN(4)
) sdram_ctrl
(
	.sd_cke   (sd_cke),
	.sd_cs_n  (sd_cs_n),
	.sd_ras_n (sd_ras_n),
	.sd_cas_n (sd_cas_n),
	.sd_we_n  (sd_we_n),
	.sd_ba    (sd_ba),
	.sd_a     (sd_a),
	.sd_dqm   (sd_dqm),
	.sd_dq_out(sd_dq_out),
	.sd_dq_oe (sd_dq_oe),
	.sd_dq_in (sd_dq_in),

	.clk      (clk_sys),
	.rst_n    (~sdram_init),
	.addr     (sd_addr_rel),
	.bank_sel (sd_bank),
	.din      (sd_din),
	.dout     (sd_dout),
	.dout16   (sd_dout16),
	.rd       (sd_rd),
	.we       (1'b0),
	.din_hi   (sd_din_hi),
	.we_word  (sd_we_word),
	.ready    (sd_ready),
	.req_done (sd_req_done),
	.req_hit  (sd_req_hit),
	.burst_words(sd_burst_words),
	.dout_b0    (sd_dout_b0)
);

//------------------------------------------------------------------
// SDRAM clock forwarding: the controller leaves it to the top level. Hardware needs
// a registered DDR output for correct timing; all phase comes from the PLL's second
// output (clk_sdram), and the DDIO only forwards it, non-inverting. Simulation does
// not support the Altera primitive.
//------------------------------------------------------------------
generate
	if (USE_ALTDDIO) begin : g_ddr_clk
		altddio_out #(
			.extend_oe_disable    ("OFF"),
			.intended_device_family("Cyclone V"),
			.invert_output        ("OFF"),
			.lpm_hint             ("UNUSED"),
			.lpm_type             ("altddio_out"),
			.oe_reg               ("UNREGISTERED"),
			.power_up_high        ("OFF"),
			.width                (1)
		) sdramclk_ddr (
			.datain_h  (1'b1),
			.datain_l  (1'b0),
			.outclock  (clk_sdram),
			.dataout   (SDRAM_CLK),
			.aclr      (1'b0),
			.aset      (1'b0),
			.oe        (1'b1),
			.outclocken(1'b1),
			.sclr      (1'b0),
			.sset      (1'b0)
		);
	end else begin : g_sim_clk
		assign SDRAM_CLK = clk_sdram;
	end
endgenerate

//------------------------------------------------------------------
// ioctl -> SDRAM write
//
// The MRA delivers one flat index-0 download (after the 16-byte header) whose
// addresses are the SDRAM addresses, so the core routes by ioctl_addr range instead
// of by index:
//   master ROM  ADDR_MASTER_BASE+   256 KB
//   slave ROM   ADDR_SLAVE_BASE+    ~576 KB
//   sound ROM   ADDR_SOUND_BASE+    1 MB (sparse)
//   gfx, PROM and the EEPROM image follow (see leland_board_pkg.sv)
// All of it goes through the same gate, FIFO and pair-write pipeline. ioctl_download
// drops only once, at the true end of loading; with several separate download
// sessions it would drop between each and start the CPUs early.
//------------------------------------------------------------------

// ioctl_addr delayed one clk_sys cycle (declared here because it is used just below).
reg [26:0] ioctl_addr_d1;
always @(posedge clk_sys) ioctl_addr_d1 <= ioctl_addr;

//------------------------------------------------------------------
// 16-byte MRA header: the first HDR_LEN bytes of the index-0 stream are metadata, not
// ROM content. sdram_addr is only meaningful once ioctl_addr_d1 is past the header.
//------------------------------------------------------------------
wire ioctl_wr_hdr = ioctl_wr && ioctl_download && (ioctl_index[7:0] == 8'h00) &&
                    (ioctl_addr_d1 < HDR_LEN[26:0]);

reg [7:0] hdr_board_class_raw;
reg [7:0] hdr_game_id;
reg [7:0] hdr_input_scheme_raw;
reg [7:0] hdr_flags;

always @(posedge clk_sys) begin
	if (ioctl_wr_hdr) begin
		case (ioctl_addr_d1[3:0])
			HDR_OFF_BOARD_CLASS[3:0]:  hdr_board_class_raw  <= ioctl_data;
			HDR_OFF_GAME_ID[3:0]:      hdr_game_id           <= ioctl_data;
			HDR_OFF_INPUT_SCHEME[3:0]: hdr_input_scheme_raw  <= ioctl_data;
			HDR_OFF_FLAGS[3:0]:        hdr_flags             <= ioctl_data;
			default: ; // magic/version/reserved: not consumed by the loader
		endcase
	end
end

// board_class selects the write gate's upper bound through a real case statement
// (every game currently resolves to GEN3_LELANDI; later board classes diverge here).
board_class_e board_class_r;
assign board_class_r = board_class_e'(hdr_board_class_raw);

// game_id (header byte 3) indexes the package's per-game config table for I/O bases,
// input scheme and flags. The header's own board_class/input_scheme/flags bytes are
// only sanity-check values; the table is authoritative.
leland_board_pkg::game_cfg_t game_cfg_r;
assign game_id    = (FIXED_GAME_ID < 0) ? hdr_game_id : FIXED_GAME_ID[7:0];
assign game_cfg_r = leland_board_pkg::game_cfg(game_id);

wire [7:0] io_base_r    = game_cfg_r.io_base;
wire [7:0] mvram_base_r = game_cfg_r.mvram_base;
wire       dual_io_window_r = game_cfg_r.flags[leland_board_pkg::FLAG_DUAL_IO_WINDOW];
wire       in4_port_en_r    = game_cfg_r.flags[leland_board_pkg::FLAG_IN4_PORT];
wire       slave_1mb_r      = game_cfg_r.flags[leland_board_pkg::FLAG_SLAVE_1MB];
wire       gfx_wide_r       = game_cfg_r.flags[leland_board_pkg::FLAG_GFX_WIDE];
wire       joy3_sel         = (game_cfg_r.input_scheme == leland_board_pkg::JOY3_DIGITAL);
leland_board_pkg::input_scheme_e input_scheme_r;
assign input_scheme_r = game_cfg_r.input_scheme;

// gfx/prom tile ROMs live in SDRAM, so the write gate's upper bound covers only the
// real populated content, not the full PROM reservation.
localparam [26:0] ADDR_GFX_REAL_HI  = ADDR_GFX_BASE  + 27'h018000;
localparam [26:0] ADDR_PROM_REAL_HI = ADDR_PROM_BASE + 27'h020000;
// The EEPROM default image (128 bytes = 64 x 16-bit words) follows at ADDR_EEPROM_BASE;
// the write gate extends to cover it (real content only, like the bounds above).
localparam [26:0] ADDR_EEPROM_REAL_HI = ADDR_EEPROM_BASE + 27'h000080;
localparam [26:0] ADDR_EEPROM_REAL_HI_G4 = ADDR_EEPROM_BASE + 27'h000100;

wire wsf_sel   = (game_cfg_r.board_class == GEN4_WSF);
wire ataxx_sel = (game_cfg_r.board_class == GEN4_ATAXX) || wsf_sel;
assign ax_video = ataxx_sel;

logic [26:0] wr_gate_hi;
always @(*) begin
	case (game_cfg_r.board_class)
		GEN3_LELANDI: wr_gate_hi = ADDR_EEPROM_REAL_HI;
		GEN4_ATAXX:   wr_gate_hi = ADDR_EEPROM_REAL_HI_G4;
		GEN4_WSF:     wr_gate_hi = ADDR_EEPROM_REAL_HI_G4;
		default:      wr_gate_hi = ADDR_EEPROM_REAL_HI;
	endcase
end

// sdram_addr = ioctl_addr - HDR_LEN, valid once past the header.
wire [26:0] sdram_addr = ioctl_addr_d1 - HDR_LEN[26:0];

// The ioctl_index==0 qualifier is required: the ARM also sends other data over ioctl
// (e.g. index 254) that would otherwise overwrite the ROM at low addresses.
wire ioctl_wr_rom = ioctl_wr && ioctl_download && (ioctl_index[7:0] == 8'h00) &&
                    (ioctl_addr_d1 >= HDR_LEN[26:0]) && (sdram_addr < wr_gate_hi);

// Downloads settled: at least one download has been seen and ioctl_download has stayed
// low for DL_SETTLE_CYCLES. Gates the CPUs and the boot FSMs.
reg        dl_seen;
reg [23:0] dl_settle_cnt;
wire       dl_settled = dl_seen && !ioctl_download &&
                        (dl_settle_cnt >= DL_SETTLE_CYCLES[23:0]);
always @(posedge clk_sys) begin
	if (sdram_init) begin
		dl_seen       <= 1'b0;
		dl_settle_cnt <= 24'd0;
	end else if (ioctl_download) begin
		dl_seen       <= 1'b1;
		dl_settle_cnt <= 24'd0;
	end else if (dl_settle_cnt != 24'hFFFFFF) begin
		dl_settle_cnt <= dl_settle_cnt + 24'd1;
	end
end

// hps_io advances ioctl_addr in the same cycle it sets its internal write flag, and
// ioctl_wr is that flag delayed one cycle, so a locally delayed copy of ioctl_addr
// (ioctl_addr_d1, above) is what pairs each byte with its own address.
// The latched_* registers below hold the pair being written: the SDRAM write is a
// multi-cycle transaction, and driving it from the live ioctl signals relied on the HPS
// holding them stable for its whole duration.
reg [26:0] latched_ioctl_addr;      // always the EVEN (word) address of the pair
reg  [7:0] latched_ioctl_data;      // low/even byte
reg  [7:0] latched_ioctl_data_hi;   // high/odd byte -- see paired-write comment below

// Master (0x000000+) and Slave/Sound (ADDR_SLAVE_BASE+) ROM share this
// pipeline in the flat post-header address space AND are numerically identical
// to their SDRAM addresses -- no per-region offset math needed at all,
// unlike the old ioctl_index-keyed version. Straight pass-through.
// Renamed to _ioctl (final sdram_wr_* muxed against the gfx-repack FSM
// further below, after wr_pending/dl_settled are in scope).
wire [24:0] sdram_wr_addr_ioctl    = latched_ioctl_addr[24:0];
wire  [7:0] sdram_wr_data_ioctl    = latched_ioctl_data;
wire  [7:0] sdram_wr_data_hi_ioctl = latched_ioctl_data_hi;

//------------------------------------------------------------------
// Non-lossy ioctl capture: a skid FIFO between hps_io and the SDRAM write channel.
//
// hps_io does not honour ioctl_wait itself; it is only exported to the ARM, which polls
// it in software, so strobes keep arriving (a few clk_sys cycles apart) until the ARM
// reacts. Accepting a strobe only while the write channel is idle would drop them, so
// every strobe is captured unconditionally into a 32-entry FIFO drained at SDRAM pace.
// ioctl_wait asserts at half full, leaving 16 slots for the ARM's reaction time.
//------------------------------------------------------------------
localparam WFIFO_AW = 5;                    // 32 entries
// {addr[24:0], data[7:0]}: 25 address bits. The gfx/prom regions (up to 0x620000) need 23
// and the Gen4 EEPROM default image at ADDR_EEPROM_BASE (0x800000) needs bit 23; a 23-bit
// field wrapped those bytes onto address 0 and overwrote the master ROM reset code. The
// field holds sdram_addr (post-header); the region is derived from the address at drain time.
reg [32:0] wfifo [0:(1<<WFIFO_AW)-1];
reg [WFIFO_AW:0] wfifo_wptr, wfifo_rptr;    // extra bit for full/empty
wire [WFIFO_AW:0] wfifo_level = wfifo_wptr - wfifo_rptr;
wire [WFIFO_AW-1:0] wfifo_rptr_p1 = wfifo_rptr[WFIFO_AW-1:0] + 1'b1; // odd entry of a pair
wire wfifo_empty = (wfifo_level == 0);
wire wfifo_full  = wfifo_level[WFIFO_AW];

// Sticky overflow flag (impossible with the half-full wait threshold); read by the
// simulation testbench.
reg wfifo_overflow;

// Enqueue every ROM strobe in one cycle, with no busy check (sdram_addr is
// ioctl_addr_d1 - HDR_LEN).
always @(posedge clk_sys) begin
	if (sdram_init) begin
		wfifo_wptr     <= '0;
		wfifo_overflow <= 1'b0;
	end else if (ioctl_wr_rom) begin
		if (!wfifo_full) begin
			wfifo[wfifo_wptr[WFIFO_AW-1:0]] <= {sdram_addr[24:0], ioctl_data};
			wfifo_wptr <= wfifo_wptr + 1'd1;
		end else begin
			wfifo_overflow <= 1'b1;
		end
	end
end

// Dequeue/drain: pop a pair of bytes (the even address and its odd neighbour, which is
// always adjacent because the ROM regions start at 0 and have even length) into the
// latched_* registers and issue one 16-bit word write whenever the write channel is
// free. wr_pending means one SDRAM write is in progress.
//
// Writes are paired because DQM has no effect on which byte lane is stored on this
// board (measured), so a byte write that relies on DQM masking would corrupt the
// other lane. The word write keeps DQM at 2'b00 (sdram.sv we_word).
reg wr_pending;
always @(posedge clk_sys) begin
	if (sdram_init) begin
		wr_pending            <= 1'b0;
		wfifo_rptr            <= '0;
	end
	else if (sdram_wr_ack) begin
		wr_pending <= 1'b0;
	end
	else if (!wr_pending && (wfifo_level >= 2)) begin
		wr_pending            <= 1'b1;
		// Even entry (low byte); [32:8] is the 25-bit sdram_addr, already past the header subtract.
		latched_ioctl_addr    <= {2'b0, wfifo[wfifo_rptr[WFIFO_AW-1:0]][32:8]};
		latched_ioctl_data    <= wfifo[wfifo_rptr[WFIFO_AW-1:0]][7:0];
		// Odd entry (high byte) -- guaranteed to be rptr+1.
		latched_ioctl_data_hi <= wfifo[wfifo_rptr_p1][7:0];
		wfifo_rptr            <= wfifo_rptr + 2'd2;
	end
end

// ioctl_wait: asserted while SDRAM init is pending and once the write FIFO is half
// full. It is an early warning with slack (8 free slots), not a per-byte stop,
// because the ARM reacts to it in software with real latency.
assign ioctl_wait   = (wfifo_level >= (1<<(WFIFO_AW-1))) | ~sdram_ready;

//------------------------------------------------------------------
// gfx repack: one-shot boot FSM that runs after dl_settled and before video_release.
// It builds two derived copies of bg_gfx in SDRAM (the loaded ROM is left as is):
//   ADDR_GFXW_BASE    16-bit words {plane1, plane0}
//   ADDR_GFXROW_BASE  4-byte entries {8'h00, plane2, plane1, plane0}, which
//                     leland_video reads with one 2-word burst
// It borrows the rd2 and write channels, which are idle then: leland_video is held in
// reset until video_release (gated on repack_done) and the ioctl write FIFO has long
// drained. A plain mux is enough because the users are mutually exclusive in time.
localparam [16:0] REPACK_LEN = 17'h8000; // one plane's worth of bytes

// The GFXROW entry layout is described at ADDR_GFXROW_BASE in leland_board_pkg.sv.
typedef enum logic [3:0] {
	RP_IDLE, RP_RD0_REQ, RP_RD0_WAIT, RP_RD1_REQ, RP_RD1_WAIT,
	RP_RD2_REQ, RP_RD2_WAIT,
	RP_WR_REQ, RP_WR_WAIT, RP_WR2_REQ, RP_WR2_WAIT,
	RP_WR3_REQ, RP_WR3_WAIT, RP_DONE
} repack_state_e;

repack_state_e repack_st;
reg [16:0] repack_idx;
reg  [7:0] repack_b0;
reg  [7:0] repack_b2; // plane2 byte, latched at RP_RD2_WAIT for the GFXROW word1 write
reg        repack_done_g;

reg        repack_rd_req_r;
reg [24:0] repack_rd_addr_r;
reg        repack_wr_req_r;
reg [24:0] repack_wr_addr_r;
reg  [7:0] repack_wr_data_r, repack_wr_data_hi_r;

wire repack_active = (repack_st != RP_IDLE) && (repack_st != RP_DONE);

always @(posedge clk_sys) begin
	if (sdram_init) begin
		repack_st       <= RP_IDLE;
		repack_idx      <= 17'd0;
		repack_done_g     <= 1'b0;
		repack_rd_req_r <= 1'b0;
		repack_wr_req_r <= 1'b0;
	end else begin
		case (repack_st)
			RP_IDLE: if (dl_settled && !wr_pending) begin
				if (ataxx_sel) repack_st <= RP_DONE;
				else           repack_st <= RP_RD0_REQ;
			end

			// plane0[idx] -- ADDR_GFX_BASE + idx (u93, the first 32KB third)
			RP_RD0_REQ: begin
				repack_rd_addr_r <= ADDR_GFX_BASE[24:0] + {8'b0, repack_idx};
				repack_rd_req_r  <= 1'b1;
				repack_st        <= RP_RD0_WAIT;
			end
			RP_RD0_WAIT: if (sdram_rd2_ack) begin
				repack_b0       <= sdram_rd2_data;
				repack_rd_req_r <= 1'b0;
				repack_st       <= RP_RD1_REQ;
			end

			// plane1[idx] -- ADDR_GFX_BASE + 0x8000 + idx (u94, the second third)
			RP_RD1_REQ: begin
				repack_rd_addr_r <= ADDR_GFX_BASE[24:0] + 25'h008000 + {8'b0, repack_idx};
				repack_rd_req_r  <= 1'b1;
				repack_st        <= RP_RD1_WAIT;
			end
			RP_RD1_WAIT: if (sdram_rd2_ack) begin
				repack_wr_data_r    <= repack_b0;      // low byte  = plane0
				repack_wr_data_hi_r <= sdram_rd2_data;  // high byte = plane1
				repack_rd_req_r     <= 1'b0;
				repack_st           <= RP_RD2_REQ;
			end

			// plane2[idx] -- ADDR_GFX_BASE + 0x10000 + idx (u95, the third third)
			RP_RD2_REQ: begin
				repack_rd_addr_r <= ADDR_GFX_BASE[24:0] + 25'h010000 + {8'b0, repack_idx};
				repack_rd_req_r  <= 1'b1;
				repack_st        <= RP_RD2_WAIT;
			end
			RP_RD2_WAIT: if (sdram_rd2_ack) begin
				repack_b2       <= sdram_rd2_data;
				repack_rd_req_r <= 1'b0;
				repack_st       <= RP_WR_REQ;
			end

				// combined word -> ADDR_GFXW_BASE + idx*2
			RP_WR_REQ: begin
				repack_wr_addr_r <= ADDR_GFXW_BASE[24:0] + {repack_idx, 1'b0};
				repack_wr_req_r  <= 1'b1;
				repack_st        <= RP_WR_WAIT;
			end
			RP_WR_WAIT: if (sdram_wr_ack) begin
				repack_wr_req_r <= 1'b0;
				repack_st       <= RP_WR2_REQ;
			end

				// GFXROW word0 = {plane1, plane0} at ADDR_GFXROW_BASE + idx*4. repack_wr_data_hi_r
				// still holds plane1 from RP_RD1_WAIT; plane0 is re-latched from repack_b0 so the
				// state does not depend on that.
			RP_WR2_REQ: begin
				repack_wr_addr_r <= ADDR_GFXROW_BASE[24:0] + {repack_idx, 2'b00};
				repack_wr_data_r <= repack_b0; // plane0
				repack_wr_req_r  <= 1'b1;
				repack_st        <= RP_WR2_WAIT;
			end
			RP_WR2_WAIT: if (sdram_wr_ack) begin
				repack_wr_req_r <= 1'b0;
				repack_st       <= RP_WR3_REQ;
			end

			// GFXROW word1 = {8'h00, plane2} at ADDR_GFXROW_BASE + idx*4 + 2.
			RP_WR3_REQ: begin
				repack_wr_addr_r    <= ADDR_GFXROW_BASE[24:0] + {repack_idx, 2'b00} + 25'd2;
				repack_wr_data_r    <= repack_b2;  // low byte  = plane2
				repack_wr_data_hi_r <= 8'h00;      // high byte = padding
				repack_wr_req_r     <= 1'b1;
				repack_st           <= RP_WR3_WAIT;
			end
			RP_WR3_WAIT: if (sdram_wr_ack) begin
				repack_wr_req_r <= 1'b0;
				if (repack_idx == REPACK_LEN - 17'd1) begin
					repack_st   <= RP_DONE;
					repack_done_g <= 1'b1;
				end else begin
					repack_idx  <= repack_idx + 17'd1;
					repack_st   <= RP_RD0_REQ;
				end
			end

			default: ; // RP_DONE: parked here for the rest of time
		endcase
	end
end

// Gen 4 (Ataxx, Indy Heat, Brute Force) has no graphics repack: the MRA byte-interleaves the six
// plane files into 8-byte tile rows (plane0..plane5, then 2 pad bytes) as they load, at
// ADDR_GFX_BASE, and leland_video fetches a row with one 4-word burst. Those boards are
// ready as soon as the download has settled.
wire repack_done = ataxx_sel ? dl_settled : repack_done_g;

//------------------------------------------------------------------
// Per-game EEPROM default content: runs once after repack_done, borrowing the same
// rd2 channel (never active at the same time as the repack). Reads the 128-byte image
// delivered by the MRA at ADDR_EEPROM_BASE (big-endian words, high byte first, as in
// leland_eeprom_93c46) and writes all 64 words into the EEPROM before the CPUs start.
//------------------------------------------------------------------
typedef enum logic [2:0] {
	EE_IDLE, EE_RD_HI_REQ, EE_RD_HI_WAIT, EE_RD_LO_REQ, EE_RD_LO_WAIT, EE_WR, EE_DONE
} ee_state_e;

ee_state_e ee_st;
reg  [6:0] ee_idx;
reg  [7:0] ee_hi;
reg        ee_done;

reg        ee_rd_req_r;
reg [24:0] ee_rd_addr_r;
reg        ee_mem_wr_r;
reg  [6:0] ee_mem_wr_addr_r;
reg [15:0] ee_mem_wr_data_r;

wire ee_active = (ee_st != EE_IDLE) && (ee_st != EE_DONE);

always @(posedge clk_sys) begin
	ee_mem_wr_r <= 1'b0;
	if (sdram_init) begin
		ee_st       <= EE_IDLE;
		ee_idx      <= 7'd0;
		ee_done     <= 1'b0;
		ee_rd_req_r <= 1'b0;
	end else begin
		case (ee_st)
			EE_IDLE: if (repack_done) ee_st <= EE_RD_HI_REQ;

			EE_RD_HI_REQ: begin
				ee_rd_addr_r <= ADDR_EEPROM_BASE[24:0] + {17'b0, ee_idx, 1'b0};
				ee_rd_req_r  <= 1'b1;
				ee_st        <= EE_RD_HI_WAIT;
			end
			EE_RD_HI_WAIT: if (sdram_rd2_ack) begin
				ee_hi       <= sdram_rd2_data;
				ee_rd_req_r <= 1'b0;
				ee_st       <= EE_RD_LO_REQ;
			end

			EE_RD_LO_REQ: begin
				ee_rd_addr_r <= ADDR_EEPROM_BASE[24:0] + {17'b0, ee_idx, 1'b0} + 25'd1;
				ee_rd_req_r  <= 1'b1;
				ee_st        <= EE_RD_LO_WAIT;
			end
			EE_RD_LO_WAIT: if (sdram_rd2_ack) begin
				ee_mem_wr_data_r <= {ee_hi, sdram_rd2_data};
				// Latch the destination index here, with the data: ee_mem_wr_r is a registered
				// pulse that lands the cycle after EE_WR, by which time ee_idx has advanced.
				ee_mem_wr_addr_r <= ee_idx;
				ee_rd_req_r      <= 1'b0;
				ee_st            <= EE_WR;
			end

			EE_WR: begin
				ee_mem_wr_r <= 1'b1;
				if (ee_idx == (ataxx_sel ? 7'd127 : 7'd63)) begin
					ee_st   <= EE_DONE;
					ee_done <= 1'b1;
				end else begin
					ee_idx <= ee_idx + 7'd1;
					ee_st  <= EE_RD_HI_REQ;
				end
			end

			default: ; // EE_DONE: parked here for the rest of time
		endcase
	end
end

// Saved settings (ioctl_index 4, 128 bytes, or 256 for Ataxx, big-endian words like the
// default image).
// They can arrive before or after the default load above, so once a save file has
// been seen the default load stops writing, and the save file always wins.
localparam [15:0] NVRAM_INDEX = 16'd4;

reg [26:0] nvl_addr_d1;
always @(posedge clk_sys) nvl_addr_d1 <= nvl_addr;

wire       ioctl_wr_nv = nvl_wr && nvl_download && (nvl_index == NVRAM_INDEX);
reg        nv_seen;
reg  [7:0] nv_hi;
reg        nv_mem_wr_r;
reg  [6:0] nv_mem_wr_addr_r;
reg [15:0] nv_mem_wr_data_r;

always @(posedge clk_sys) begin
	nv_mem_wr_r <= 1'b0;
	if (sdram_init) nv_seen <= 1'b0;
	else if (nvl_download && (nvl_index == NVRAM_INDEX)) nv_seen <= 1'b1;

	if (ioctl_wr_nv && (nvl_addr_d1 < (ataxx_sel ? 27'd256 : 27'd128))) begin
		if (!nvl_addr_d1[0]) begin
			nv_hi <= nvl_data;
		end else begin
			nv_mem_wr_r      <= 1'b1;
			nv_mem_wr_addr_r <= nvl_addr_d1[7:1];
			nv_mem_wr_data_r <= {nv_hi, nvl_data};
		end
	end
end

wire        eeprom_mem_wr      = nv_mem_wr_r | (ee_mem_wr_r & ~nv_seen);
wire  [6:0] eeprom_mem_wr_addr = nv_mem_wr_r ? nv_mem_wr_addr_r : ee_mem_wr_addr_r;
wire [15:0] eeprom_mem_wr_data = nv_mem_wr_r ? nv_mem_wr_data_r : ee_mem_wr_data_r;

// Final muxes: the repack FSM and the EEPROM loader borrow rd2/wr while active
// (mutually exclusive: EE_IDLE only advances once repack_done); otherwise
// leland_video's request and the ioctl loader's write pass straight through.
assign sdram_rd2_req  = repack_active ? repack_rd_req_r  : (ee_active ? ee_rd_req_r  : sdram_rd2_req_v);
assign sdram_rd2_addr = repack_active ? repack_rd_addr_r : (ee_active ? ee_rd_addr_r : sdram_rd2_addr_v);

assign sdram_wr_req      = repack_active ? repack_wr_req_r     : wr_pending;
assign sdram_wr_addr     = repack_active ? repack_wr_addr_r    : sdram_wr_addr_ioctl;
assign sdram_wr_data     = repack_active ? repack_wr_data_r    : sdram_wr_data_ioctl;
assign sdram_wr_data_hi  = repack_active ? repack_wr_data_hi_r : sdram_wr_data_hi_ioctl;

//------------------------------------------------------------------
// Graphics and palette ROMs live in SDRAM like all other ROM content (loaded through
// the same write FIFO, fetched by leland_video through the rd2 channel); there are no
// block-RAM copies.
//------------------------------------------------------------------

//------------------------------------------------------------------
// Video RAM — 64 KB dual-port (Master+Slave VRAM I/O ports write/read
// through the sequencer below, video reads through port B)
//------------------------------------------------------------------
reg  [16:0] vram_addr_cpu;
reg   [7:0] vram_din_cpu;
reg         vram_we_cpu;
wire  [7:0] vram_dout_cpu;
wire [16:0] vram_addr_vid;
wire [7:0] vram_dout_vid, vram_live_data;
wire snapshot_pause, snapshot_capture, snapshot_valid, snapshot_fault;
wire master_bus_held, slave_bus_held;
wire render_group_active, render_group_done;
wire [15:0] snapshot_capture_addr;
wire [10:0] snapshot_capture_pal_addr;
wire [7:0] snapshot_pal_data;
wire [15:0] vram_read_addr = snapshot_capture ? snapshot_capture_addr : vram_addr_vid[15:0];

// Every sequencer address and the video address have a constant zero bit 16.
// Declare the reachable depth explicitly: Q17 otherwise retains two 128-KB
// copies to preserve the generic RAM's same-port OLD_DATA contract.
// The sequencer consumes A only after reads (SEQ_POP/SEQ_TPOP), never on
// writes. Use the qualified compact primitive: A write-first is unobserved,
// while the video port retains OLD_DATA on same-address write collisions.
leland_qram_compact_candidate #(.ADDR_WIDTH(16), .DATA_WIDTH(8)) vram
(
	.clk(clk_sys),
	.addr_a(vram_addr_cpu[15:0]), .din_a(vram_din_cpu), .we_a(vram_we_cpu), .dout_a(vram_dout_cpu),
	.addr_b(vram_read_addr), .din_b(8'd0), .we_b(1'b0), .dout_b(vram_live_data)
);

//------------------------------------------------------------------
// VRAM I/O port sequencer — arbitrates the Master's and Slave's
// leland_vram_port elementary op streams (vp_req/vp_rd/vp_trans/vp_addr/
// vp_data) against the single CPU-side VRAM BRAM port A. Fixed
// priority: Slave first (it is the primary VRAM/blit user), then
// Master (used far less often -- boot handshake mailbox only).
//
// Transparent writes (vp_trans, Slave-only in MAME) implement the
// exact leland_v.cpp vram_port_w merge:
//   if (!(data & 0xf0)) data |= old & 0xf0;
//   if (!(data & 0x0f)) data |= old & 0x0f;
// by inserting a read phase before the write phase.
//------------------------------------------------------------------
wire        vp_req_m, vp_rd_m, vp_trans_m;
wire [15:0] vp_addr_m;
wire  [7:0] vp_data_m;
reg         vp_pop_m;
reg   [7:0] vp_rdata_m;

wire        vp_req_s, vp_rd_s, vp_trans_s;
wire [15:0] vp_addr_s;
wire  [7:0] vp_data_s;
reg         vp_pop_s;
reg   [7:0] vp_rdata_s;

localparam SEQ_IDLE = 3'd0, SEQ_ADDR = 3'd1, SEQ_POP = 3'd2,
           SEQ_TRD   = 3'd3, SEQ_TPOP = 3'd4, SEQ_TWR  = 3'd5, SEQ_TWPOP = 3'd6;
reg [2:0] seq_state;
reg       cur_side;   // 0 = master, 1 = slave
reg       cur_rd;
reg [15:0] cur_addr;
reg  [7:0] cur_data;

always @(posedge clk_sys) begin
	vp_pop_m <= 1'b0;
	vp_pop_s <= 1'b0;
	if (reset) begin
		seq_state   <= SEQ_IDLE;
		vram_we_cpu <= 1'b0;
	end else begin
		case (seq_state)
				// The !vp_pop_* guards are needed: vp_pop_* are registered one-cycle pulses and
				// leland_vram_port clears its head on the same edge, so vp_req_* still shows the
				// pre-pop value while seq_state is back here. Without them every op runs twice.
			SEQ_IDLE: begin
				vram_we_cpu <= 1'b0;
				if (vp_req_s && !vp_pop_s) begin
					cur_side <= 1'b1;
					cur_rd   <= vp_rd_s;
					cur_addr <= vp_addr_s;
					cur_data <= vp_data_s;
					if (vp_trans_s && !vp_rd_s) begin
						vram_addr_cpu <= {1'b0, vp_addr_s};
						vram_we_cpu   <= 1'b0;
						seq_state     <= SEQ_TRD;
					end else begin
						vram_addr_cpu <= {1'b0, vp_addr_s};
						vram_din_cpu  <= vp_data_s;
						vram_we_cpu   <= ~vp_rd_s;
						seq_state     <= SEQ_ADDR;
					end
				end else if (vp_req_m && !vp_pop_m) begin
					cur_side <= 1'b0;
					cur_rd   <= vp_rd_m;
					cur_addr <= vp_addr_m;
					cur_data <= vp_data_m;
					vram_addr_cpu <= {1'b0, vp_addr_m};
					vram_din_cpu  <= vp_data_m;
					vram_we_cpu   <= ~vp_rd_m;
					seq_state     <= SEQ_ADDR;
				end
			end

			// Plain read/write: address held for one cycle, BRAM's
			// registered output/write completes on the next edge.
			SEQ_ADDR: begin
				vram_we_cpu <= 1'b0;
				seq_state   <= SEQ_POP;
			end
			SEQ_POP: begin
				if (cur_rd) begin
					if (cur_side) vp_rdata_s <= vram_dout_cpu;
					else          vp_rdata_m <= vram_dout_cpu;
				end
				if (cur_side) vp_pop_s <= 1'b1;
				else          vp_pop_m <= 1'b1;
				seq_state <= SEQ_IDLE;
			end

			// Transparent write: read old byte first, merge zero
			// nibbles from the old VRAM byte, then write the result.
			SEQ_TRD: seq_state <= SEQ_TPOP;
			SEQ_TPOP: begin
				vram_addr_cpu <= {1'b0, cur_addr};
				vram_din_cpu  <= { (cur_data[7:4] == 4'h0) ? vram_dout_cpu[7:4] : cur_data[7:4],
				                    (cur_data[3:0] == 4'h0) ? vram_dout_cpu[3:0] : cur_data[3:0] };
				vram_we_cpu   <= 1'b1;
				seq_state     <= SEQ_TWR;
			end
			SEQ_TWR: begin
				vram_we_cpu <= 1'b0;
				seq_state   <= SEQ_TWPOP;
			end
			SEQ_TWPOP: begin
				if (cur_side) vp_pop_s <= 1'b1;
				else          vp_pop_m <= 1'b1;
				seq_state <= SEQ_IDLE;
			end

			default: seq_state <= SEQ_IDLE;
		endcase
	end
end

//------------------------------------------------------------------
// Work RAM: 4 KB per CPU, private (MAME: the master's 0xE000-0xEFFF is 'mainram',
// the slave's is a separate RAM). The CPUs only communicate through VRAM and the
// SLAVEHALT poll.
//------------------------------------------------------------------
wire [11:0] wram_addr_mg;
wire [12:0] wram_addr_s;
wire  [7:0] wram_din_mg, wram_din_s;
wire        wram_we_mg, wram_we_s;
wire [12:0] wram_addr_ma;
wire  [7:0] wram_din_ma;
wire        wram_we_ma;
wire  [7:0] wram_dout_m, wram_dout_s;

wire [12:0] wram_addr_m = ataxx_sel ? wram_addr_ma : {1'b0, wram_addr_mg};
wire  [7:0] wram_din_m  = ataxx_sel ? wram_din_ma  : wram_din_mg;
wire        wram_we_m   = ataxx_sel ? wram_we_ma   : wram_we_mg;

leland_dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) wram_m
(
	.clk(clk_sys),
	.addr_a(wram_addr_m), .din_a(wram_din_m), .we_a(wram_we_m), .dout_a(wram_dout_m),
	.addr_b(13'd0), .din_b(8'd0), .we_b(1'b0), .dout_b()
);

leland_dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) wram_s
(
	.clk(clk_sys),
	.addr_a(wram_addr_s), .din_a(wram_din_s), .we_a(wram_we_s), .dout_a(wram_dout_s),
	.addr_b(13'd0), .din_b(8'd0), .we_b(1'b0), .dout_b()
);

//------------------------------------------------------------------
// Battery-backed RAM: 16 KB, master-private (0xA000-0xDFFF, selected when
// bank_reg==1). Volatile here; on a blank board the game's own recovery path
// writes the magic signature and defaults.
//------------------------------------------------------------------
wire [13:0] battram_addr_mg, battram_addr_ma;
wire  [7:0] battram_din_mg,  battram_din_ma;
wire        battram_we_mg,   battram_we_ma;
wire  [7:0] battram_dout_m;

wire [13:0] battram_addr_m = ataxx_sel ? battram_addr_ma : battram_addr_mg;
wire  [7:0] battram_din_m  = ataxx_sel ? battram_din_ma  : battram_din_mg;
wire        battram_we_m   = ataxx_sel ? battram_we_ma   : battram_we_mg;

leland_dpram #(.ADDR_WIDTH(14), .DATA_WIDTH(8)) battram_m
(
	.clk(clk_sys),
	.addr_a(battram_addr_m), .din_a(battram_din_m), .we_a(battram_we_m), .dout_a(battram_dout_m),
	.addr_b(14'd0), .din_b(8'd0), .we_b(1'b0), .dout_b()
);

//------------------------------------------------------------------
// EEPROM (93C46, 64 x 16-bit): DI/CLK/CS on /MCONT bits 4/5/6, DO on GIN3 bit 0
// (see leland_master.sv).
//------------------------------------------------------------------
wire eeprom_di_g, eeprom_clk_g, eeprom_cs_g, eeprom_do_g;
wire eeprom_di_a, eeprom_clk_a, eeprom_cs_a, eeprom_do_a;
wire [7:0] nv_rd_data_g, nv_rd_data_a;
wire        nv_dirty_g, nv_dirty_a;

leland_eeprom_93c46 eeprom
(
	.clk_sys(clk_sys),
	.reset(reset),
	.cs(eeprom_cs_g),
	.clk_in(eeprom_clk_g),
	.di(eeprom_di_g),
	.do_out(eeprom_do_g),

	.mem_wr(eeprom_mem_wr & ~ataxx_sel),
	.mem_wr_addr(eeprom_mem_wr_addr[5:0]),
	.mem_wr_data(eeprom_mem_wr_data),

	.nv_rd_addr(nv_rd_addr[6:0]),
	.nv_rd_data(nv_rd_data_g),
	.nv_dirty(nv_dirty_g),
	.nv_dirty_clr(nv_dirty_clr)
);

// Ataxx: 93C56, 128 x 16-bit, read through port 0x20
leland_eeprom_93c56 eeprom_ax
(
	.clk_sys(clk_sys),
	.reset(reset),
	.cs(eeprom_cs_a),
	.clk_in(eeprom_clk_a),
	.di(eeprom_di_a),
	.do_out(eeprom_do_a),

	.mem_wr(eeprom_mem_wr & ataxx_sel),
	.mem_wr_addr(eeprom_mem_wr_addr),
	.mem_wr_data(eeprom_mem_wr_data),

	.nv_rd_addr(nv_rd_addr),
	.nv_rd_data(nv_rd_data_a),
	.nv_dirty(nv_dirty_a),
	.nv_dirty_clr(nv_dirty_clr)
);

assign nv_rd_data = ataxx_sel ? nv_rd_data_a : nv_rd_data_g;
assign nv_dirty   = ataxx_sel ? nv_dirty_a   : nv_dirty_g;

//------------------------------------------------------------------
// Ataxx tile RAM (64 KB) and palette RAM (2 KB, xRGB-444 little-endian words);
// port B is reserved for the Ataxx video path.
//------------------------------------------------------------------
wire [15:0] qram_addr_ma;
wire  [7:0] qram_din_ma;
wire        qram_we_ma;
wire  [7:0] qram_dout_ma;
wire [15:0] qram_addr_vid;
wire  [7:0] qram_dout_vid;

// Dedicated one-clock M10K: CPU write reply is NEW_DATA (not consumed),
// video same-address collisions remain OLD_DATA; preserves zero power-up.
leland_qram_compact_candidate #(.ADDR_WIDTH(16), .DATA_WIDTH(8)) qram
(
	.clk(clk_sys),
	.addr_a(qram_addr_ma), .din_a(qram_din_ma), .we_a(qram_we_ma), .dout_a(qram_dout_ma),
	.addr_b(qram_addr_vid), .din_b(8'd0), .we_b(1'b0), .dout_b(qram_dout_vid)
);

wire [10:0] pal_addr_ma;
wire  [7:0] pal_din_ma;
wire        pal_we_ma;
wire  [7:0] pal_dout_ma;
wire [10:0] pal_addr_vid;
wire [7:0] pal_live_data;
wire [10:0] pal_read_addr = snapshot_capture ? snapshot_capture_pal_addr : pal_addr_vid;
wire  [7:0] pal_dout_vid;

leland_dpram #(.ADDR_WIDTH(11), .DATA_WIDTH(8)) palram
(
	.clk(clk_sys),
	.addr_a(pal_addr_ma), .din_a(pal_din_ma), .we_a(pal_we_ma), .dout_a(pal_dout_ma),
	.addr_b(pal_read_addr), .din_b(8'd0), .we_b(1'b0), .dout_b(pal_live_data)
);


//------------------------------------------------------------------
// Color RAM — 1 KB dual-port (Master writes, video reads)
//------------------------------------------------------------------
wire  [9:0] cram_addr_cpu;
wire  [7:0] cram_din_cpu;
wire        cram_we_cpu;
wire  [7:0] cram_dout_cpu;  // palette read-back for the master (see leland_master.sv in_cram)
wire  [9:0] cram_addr_vid;
wire  [7:0] cram_dout_vid;

leland_dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(8)) cram
(
	.clk(clk_sys),
	.addr_a(cram_addr_cpu), .din_a(cram_din_cpu), .we_a(cram_we_cpu), .dout_a(cram_dout_cpu),
	.addr_b(cram_addr_vid), .din_b(8'd0),          .we_b(1'b0),        .dout_b(cram_dout_vid)
);

//------------------------------------------------------------------
// Inter-CPU signals
//------------------------------------------------------------------
wire        slave_reset_n;
wire        slave_nmi_n;
wire        slave_int_req;
wire  [7:0] raster_line;
wire        slave_halt_n;

//------------------------------------------------------------------
// Master Z80 — SDRAM ROM stall logic
// The ROM line cache below stalls the master Z80 while a line refills.
//------------------------------------------------------------------
wire        master_rom_req;          // from leland_master
wire [19:0] master_rom_addr_w;       // from the master (flat ROM offset, XROM above 0x80000)
reg  [7:0]  master_rom_data_r;       // latched SDRAM byte

// Line cache for the master code fetch (rd0); see rtl/mem/rom_line_cache.sv.
wire master_rom_stall;
// 2 KB direct-mapped over 256 KB missed 5-6% of fetches in gameplay, and each miss
// stalls the CPU ~12 CE_6M ticks, so the cache uses 2048 lines (16 KB), which cuts
// aliasing to 16 regions per line.
rom_line_cache #(
	.BASE       (leland_board_pkg::ADDR_MASTER_BASE),
	.ADDR_WIDTH (20),
	.INDEX_BITS (11)
) rd0_cache (
	.clk_sys      (clk_sys),
	.reset        (sdram_init),
	.sdram_ready  (sdram_ready),

	.cpu_req      (master_rom_req),
	.cpu_addr     (master_rom_addr_w),
	.cpu_data     (master_rom_data_r),
	.cpu_stall    (master_rom_stall),

	.sd_req       (sdram_rd0_req),
	.sd_addr      (sdram_rd0_addr),
	.sd_data      (sdram_rd0_data),
	.sd_ack       (sdram_rd0_ack)
);

//------------------------------------------------------------------
// Master Z80
//------------------------------------------------------------------
wire [15:0] vid_addr_m;
wire        vid_addr_wr_m;
wire [15:0] scroll_x_m, scroll_y_m;
wire  [7:0] gfxbank_m;

//------------------------------------------------------------------
// CPU / video release
//
// On the board the master Z80's reset comes from an analog power-on circuit and the reset
// switch, with no relation to the raster, so the CPUs start at an arbitrary raster position.
// The raster counters here run freely from power-up and the CPUs are released as soon as the
// ROM download has finished, wherever the beam happens to be. That makes the start phase
// (and the games' timing-driven random numbers) depend on when the load completes, as it
// does on hardware, rather than on a fixed convention.
//   video_release: leland_video's fetch pipeline waits for the ROM download to finish
//     (sdram_ready, dl_settled, repack_done, on the profile's Z80 boundary).
//   cpu_release: the CPUs start on the next profile Z80 boundary after that. The legacy
//     profile retains its raw counter-zero sample; target profiles consume registered CE_6M.
//------------------------------------------------------------------
reg video_release;
always @(posedge clk_sys) begin
	if (reset || sdram_init)
		video_release <= 1'b0;
	// repack_done: leland_video must not request rd2 until the gfx-repack FSM has finished
	// borrowing it. The EEPROM load FSM also borrows rd2 but is deliberately not a gate:
	// it takes ~29 us, and gating on it delayed cpu_release enough to push the sound
	// board's boot handshake past its timeout (silent audio). A gfx fetch that lands in
	// that window is masked and simply retried.
	else if (!video_release && sdram_ready && dl_settled && repack_done && ce_release_boundary)
		video_release <= 1'b1;
end

reg cpu_release;
always @(posedge clk_sys) begin
	if (reset || sdram_init)
		cpu_release <= 1'b0;
	else if (video_release && !cpu_release && ce_release_boundary)
		cpu_release <= 1'b1;
end

// Master <-> sound-board control/command latch wires. Port 0xF0 doubles as
// the graphics bank switch and the 80186 control register.
wire  [7:0] sound_ctrl_data;
wire        sound_ctrl_wr;
wire [15:0] sound_cmd_wr_data;
wire        sound_cmd_wr_lo, sound_cmd_wr_hi;
wire  [7:0] sound_response_data; // 80186 response latch, leland_sound -> leland_master

// Per-board-class master outputs (_g: Leland gen 1-3, _a: Ataxx), muxed by ataxx_sel.
wire [17:0] master_rom_addr_g;
wire [19:0] master_rom_addr_a;
wire        master_rom_req_g,  master_rom_req_a;
wire        vp_req_mg, vp_rd_mg, vp_trans_mg;
wire [15:0] vp_addr_mg;
wire  [7:0] vp_data_mg;
wire        vp_req_ma, vp_rd_ma, vp_trans_ma;
wire [15:0] vp_addr_ma;
wire  [7:0] vp_data_ma;
wire        slave_reset_n_g, slave_nmi_n_g, slave_int_req_g;
wire        slave_reset_n_a, slave_nmi_n_a, slave_int_req_a;
wire [15:0] scroll_x_mg, scroll_y_mg, scroll_x_ma, scroll_y_ma;
wire  [7:0] sound_ctrl_data_g, sound_ctrl_data_a;
wire        sound_ctrl_wr_g,   sound_ctrl_wr_a;
wire [15:0] sound_cmd_wr_data_g, sound_cmd_wr_data_a;
wire        sound_cmd_wr_lo_g, sound_cmd_wr_hi_g, sound_cmd_wr_lo_a, sound_cmd_wr_hi_a;
wire [15:0] vid_addr_ma;
wire        vid_addr_wr_ma;
wire  [7:0] master_bank_ma;

assign master_rom_addr_w = ataxx_sel ? master_rom_addr_a : {2'b0, master_rom_addr_g};
assign master_rom_req    = ataxx_sel ? master_rom_req_a  : master_rom_req_g;
assign vp_req_m   = ataxx_sel ? vp_req_ma   : vp_req_mg;
assign vp_rd_m    = ataxx_sel ? vp_rd_ma    : vp_rd_mg;
assign vp_trans_m = ataxx_sel ? vp_trans_ma : vp_trans_mg;
assign vp_addr_m  = ataxx_sel ? vp_addr_ma  : vp_addr_mg;
assign vp_data_m  = ataxx_sel ? vp_data_ma  : vp_data_mg;
assign slave_reset_n = ataxx_sel ? slave_reset_n_a : slave_reset_n_g;
assign slave_nmi_n   = ataxx_sel ? slave_nmi_n_a   : slave_nmi_n_g;
assign slave_int_req = ataxx_sel ? slave_int_req_a : slave_int_req_g;
assign scroll_x_m = ataxx_sel ? scroll_x_ma : scroll_x_mg;
assign scroll_y_m = ataxx_sel ? scroll_y_ma : scroll_y_mg;
assign sound_ctrl_data   = ataxx_sel ? sound_ctrl_data_a   : sound_ctrl_data_g;
assign sound_ctrl_wr     = ataxx_sel ? sound_ctrl_wr_a     : sound_ctrl_wr_g;
assign sound_cmd_wr_data = ataxx_sel ? sound_cmd_wr_data_a : sound_cmd_wr_data_g;
assign sound_cmd_wr_lo   = ataxx_sel ? sound_cmd_wr_lo_a   : sound_cmd_wr_lo_g;
assign sound_cmd_wr_hi   = ataxx_sel ? sound_cmd_wr_hi_a   : sound_cmd_wr_hi_g;

// Ataxx master (held in reset unless the loaded game is Ataxx)
leland_master_ataxx #(
	.ALLOW_BUS_HOLD(ASYLUM_RENDER_SNAPSHOT),
	.Z80_RECOVERY_PROFILE(Z80_RECOVERY_PROFILE)
) master_ax
(
	.clk_sys(clk_sys),
	.reset(reset | ~cpu_release | ~ataxx_sel),
	.CE_6M(CE_6M),
	.bus_hold(snapshot_pause), .bus_held(master_bus_held),

	.wsf_mode(wsf_sel),
	.joy3_mode(joy3_sel),
	.p3_joy(p3_joy),
	.p1_pedal(p1_pedal), .p2_pedal(p2_pedal), .p3_pedal(p3_pedal),

	.rom_addr(master_rom_addr_a),
	.rom_data(master_rom_data_r),
	.rom_req(master_rom_req_a),
	.rom_stall(master_rom_stall),

	.wram_addr(wram_addr_ma),
	.wram_din(wram_din_ma),
	.wram_we(wram_we_ma),
	.wram_dout(wram_dout_m),

	.battram_addr(battram_addr_ma),
	.battram_din(battram_din_ma),
	.battram_we(battram_we_ma),
	.battram_dout(battram_dout_m),

	.qram_addr(qram_addr_ma),
	.qram_din(qram_din_ma),
	.qram_we(qram_we_ma),
	.qram_dout(qram_dout_ma),

	.pal_addr(pal_addr_ma),
	.pal_din(pal_din_ma),
	.pal_we(pal_we_ma),
	.pal_dout(pal_dout_ma),

	.vp_req(vp_req_ma),
	.vp_rd(vp_rd_ma),
	.vp_trans(vp_trans_ma),
	.vp_addr(vp_addr_ma),
	.vp_data(vp_data_ma),
	.vp_pop(vp_pop_m),
	.vp_rdata(vp_rdata_m),

	.slave_reset_n(slave_reset_n_a),
	.slave_nmi_n(slave_nmi_n_a),
	.slave_int_req(slave_int_req_a),
	.slave_halt_n(slave_halt_n),

	.vblank(VBlank),
	.raster_line(raster_line),

	.eeprom_di(eeprom_di_a),
	.eeprom_clk(eeprom_clk_a),
	.eeprom_cs(eeprom_cs_a),
	.eeprom_do(eeprom_do_a),

	.vid_addr(vid_addr_ma),
	.vid_addr_wr(vid_addr_wr_ma),
	.scroll_x(scroll_x_ma),
	.scroll_y(scroll_y_ma),
	.master_bank_o(master_bank_ma),

	.sound_ctrl_data(sound_ctrl_data_a),
	.sound_ctrl_wr(sound_ctrl_wr_a),
	.cmd_wr_data(sound_cmd_wr_data_a),
	.cmd_wr_lo(sound_cmd_wr_lo_a),
	.cmd_wr_hi(sound_cmd_wr_hi_a),
	.response_data(sound_response_data),

	.p1_x(wsf_sel ? p1_wheel : p1_tb_x), .p1_y(wsf_sel ? p2_wheel : p1_tb_y),
	.p2_x(wsf_sel ? p3_wheel : p2_tb_x), .p2_y(p2_tb_y),
	.p1_joy(p1_joy), .p2_joy(p2_joy),
	.service(service)
);

// Master Z80 (held in reset until cpu_release).
leland_master master
(
	.clk_sys(clk_sys),
	.reset(reset | ~cpu_release | ataxx_sel),
	.CE_6M(CE_6M),

	.rom_addr(master_rom_addr_g),
	.rom_data(master_rom_data_r),

	.wram_addr(wram_addr_mg),
	.wram_din(wram_din_mg),
	.wram_we(wram_we_mg),
	.wram_dout(wram_dout_m),

	.battram_addr(battram_addr_mg),
	.battram_din(battram_din_mg),
	.battram_we(battram_we_mg),
	.battram_dout(battram_dout_m),

	.cram_addr(cram_addr_cpu),
	.cram_din(cram_din_cpu),
	.cram_we(cram_we_cpu),
	.cram_dout(cram_dout_cpu),

	.vp_req(vp_req_mg),
	.vp_rd(vp_rd_mg),
	.vp_trans(vp_trans_mg),
	.vp_addr(vp_addr_mg),
	.vp_data(vp_data_mg),
	.vp_pop(vp_pop_m),
	.vp_rdata(vp_rdata_m),

	.slave_reset_n(slave_reset_n_g),
	.slave_nmi_n(slave_nmi_n_g),
	.slave_int_req(slave_int_req_g),

	.slave_halt_n(slave_halt_n),
	.vblank(VBlank),
	.raster_line(raster_line),

	.eeprom_di(eeprom_di_g),
	.eeprom_clk(eeprom_clk_g),
	.eeprom_cs(eeprom_cs_g),
	.eeprom_do(eeprom_do_g),

	.vid_addr(vid_addr_m),
	.vid_addr_wr(vid_addr_wr_m),

	.scroll_x(scroll_x_mg),
	.scroll_y(scroll_y_mg),
	.gfxbank(gfxbank_m),

	.p1_pedal(p1_pedal),
	.p2_pedal(p2_pedal),
	.p3_pedal(p3_pedal),

	.p1_wheel(p1_wheel),
	.p2_wheel(p2_wheel),
	.p3_wheel(p3_wheel),

	.p1_btn(p1_btn),
	.p2_btn(p2_btn),
	.p3_btn(p3_btn),
	.service(service),

	.io_base(io_base_r),
	.mvram_base(mvram_base_r),
	.dual_io_window(dual_io_window_r),
	.in4_port_en(in4_port_en_r),
	.input_scheme(input_scheme_r),

	.p1_joy(p1_joy),
	.p2_joy(p2_joy),
	.p3_joy(p3_joy),
	.p4_joy(p4_joy),

	.rom_req  (master_rom_req_g),
	.rom_stall(master_rom_stall),

	.sound_ctrl_data(sound_ctrl_data_g),
	.sound_ctrl_wr(sound_ctrl_wr_g),
	.cmd_wr_data(sound_cmd_wr_data_g),
	.cmd_wr_lo(sound_cmd_wr_lo_g),
	.cmd_wr_hi(sound_cmd_wr_hi_g),
	.response_data(sound_response_data)
);

//------------------------------------------------------------------
// Slave Z80 — SDRAM ROM stall logic (mirror of master scheme)
//------------------------------------------------------------------
wire        slave_rom_req;           // from leland_slave
wire [20:0] slave_rom_addr_w;        // from the slave (flat ROM offset)
reg  [7:0]  slave_rom_data_r;        // latched SDRAM byte

// Line cache for the slave code fetch (rd1).
wire slave_rom_stall;
wire        slv_sd_req;
wire [24:0] slv_sd_addr;
wire  [7:0] slv_sd_data;
wire        slv_sd_ack;
// 2 KB direct-mapped; uncached, slave code fetches stalled on up to ~8% of cycles.
rom_line_cache #(
	.BASE       (leland_board_pkg::ADDR_SLAVE_BASE),
	.ADDR_WIDTH (21),
	.INDEX_BITS (11)
) rd1_cache (
	.clk_sys      (clk_sys),
	.reset        (sdram_init),
	.sdram_ready  (sdram_ready),

	.cpu_req      (slave_rom_req),
	.cpu_addr     (slave_rom_addr_w),
	.cpu_data     (slave_rom_data_r),
	.cpu_stall    (slave_rom_stall),

	.sd_req       (slv_sd_req),
	.sd_addr      (slv_sd_addr),
	.sd_data      (slv_sd_data),
	.sd_ack       (slv_sd_ack)
);

// WSF external sample DAC: its own small line cache, sharing the slave's SDRAM channel.
wire        ext_req_w;
wire [18:0] ext_addr_w;
wire  [7:0] ext_data_w;
wire        ext_stall_w;
wire        ext_sd_req;
wire [24:0] ext_sd_addr;
wire        ext_sd_ack;
wire  [7:0] ext_sd_data;

rom_line_cache #(
	.BASE       (leland_board_pkg::ADDR_EXTDAC_BASE),
	.ADDR_WIDTH (19),
	.INDEX_BITS (6)
) ext_cache (
	.clk_sys      (clk_sys),
	.reset        (sdram_init),
	.sdram_ready  (sdram_ready),

	.cpu_req      (ext_req_w),
	.cpu_addr     (ext_addr_w),
	.cpu_data     (ext_data_w),
	.cpu_stall    (ext_stall_w),

	.sd_req       (ext_sd_req),
	.sd_addr      (ext_sd_addr),
	.sd_data      (ext_sd_data),
	.sd_ack       (ext_sd_ack)
);

// One transaction at a time; the owner is fixed from grant until its ack.
reg sd1_busy, sd1_ext;
always @(posedge clk_sys) begin
	if (sdram_init) begin
		sd1_busy <= 1'b0;
		sd1_ext  <= 1'b0;
	end else if (!sd1_busy) begin
		if (ext_sd_req)      begin sd1_busy <= 1'b1; sd1_ext <= 1'b1; end
		else if (slv_sd_req) begin sd1_busy <= 1'b1; sd1_ext <= 1'b0; end
	end else if (sdram_rd1_ack) begin
		sd1_busy <= 1'b0;
	end
end

assign sdram_rd1_req = sd1_busy && (sd1_ext ? ext_sd_req : slv_sd_req);
assign sdram_rd1_addr = sd1_ext ? ext_sd_addr : slv_sd_addr;
assign slv_sd_data = sdram_rd1_data;
assign ext_sd_data = sdram_rd1_data;
assign slv_sd_ack  = sdram_rd1_ack && sd1_busy && !sd1_ext;
assign ext_sd_ack  = sdram_rd1_ack && sd1_busy && sd1_ext;


//------------------------------------------------------------------
// Slave Z80
//------------------------------------------------------------------
// The slave is held in reset by the board reset, before cpu_release, or by the
// master's /MCONT bit 0 (slave_reset_n). The master releases it once it has
// finished its own initialisation.

wire [18:0] slave_rom_addr_g;
wire [20:0] slave_rom_addr_a;
wire        slave_rom_req_g,  slave_rom_req_a;
wire        slave_halt_n_g,   slave_halt_n_a;
wire        vp_req_sg, vp_rd_sg, vp_trans_sg, vp_req_sa, vp_rd_sa, vp_trans_sa;
wire [15:0] vp_addr_sg, vp_addr_sa;
wire  [7:0] vp_data_sg, vp_data_sa;
wire [11:0] wram_addr_sg;
wire [12:0] wram_addr_sa;
wire  [7:0] wram_din_sg, wram_din_sa;
wire        wram_we_sg, wram_we_sa;

leland_slave slave
(
	.clk_sys(clk_sys),
	.reset(reset | ~cpu_release | ~slave_reset_n | ataxx_sel),
	.CE_6M(CE_6M),

	.rom_addr(slave_rom_addr_g),
	.rom_data(slave_rom_data_r),

	.vp_req(vp_req_sg),
	.vp_rd(vp_rd_sg),
	.vp_trans(vp_trans_sg),
	.vp_addr(vp_addr_sg),
	.vp_data(vp_data_sg),
	.vp_pop(vp_pop_s),
	.vp_rdata(vp_rdata_s),

	.wram_addr(wram_addr_sg),
	.wram_din(wram_din_sg),
	.wram_we(wram_we_sg),
	.wram_dout(wram_dout_s),

	.slave_int_req(slave_int_req),
	.nmi_n(slave_nmi_n),
	.slave_halt_n(slave_halt_n_g),

	.raster_line(raster_line),

	.rom_req  (slave_rom_req_g),
	.rom_stall(slave_rom_stall)
);

assign slave_rom_addr_w = ataxx_sel ? slave_rom_addr_a : {2'b0, slave_rom_addr_g};
assign slave_rom_req    = ataxx_sel ? slave_rom_req_a  : slave_rom_req_g;
assign slave_halt_n     = ataxx_sel ? slave_halt_n_a   : slave_halt_n_g;
assign vp_req_s   = ataxx_sel ? vp_req_sa   : vp_req_sg;
assign vp_rd_s    = ataxx_sel ? vp_rd_sa    : vp_rd_sg;
assign vp_trans_s = ataxx_sel ? vp_trans_sa : vp_trans_sg;
assign vp_addr_s  = ataxx_sel ? vp_addr_sa  : vp_addr_sg;
assign vp_data_s  = ataxx_sel ? vp_data_sa  : vp_data_sg;
assign wram_addr_s = ataxx_sel ? wram_addr_sa : {1'b0, wram_addr_sg};
assign wram_din_s  = ataxx_sel ? wram_din_sa  : wram_din_sg;
assign wram_we_s   = ataxx_sel ? wram_we_sa   : wram_we_sg;

leland_slave_ataxx #(
	.ALLOW_BUS_HOLD(ASYLUM_RENDER_SNAPSHOT),
	.Z80_RECOVERY_PROFILE(Z80_RECOVERY_PROFILE)
) slave_ax
(
	.clk_sys(clk_sys),
	.reset(reset | ~cpu_release | ~slave_reset_n | ~ataxx_sel),
	.CE_6M(CE_6M),
	.bus_hold(snapshot_pause), .bus_held(slave_bus_held),
	.render_group_active(render_group_active), .render_group_done(render_group_done),

	.wsf_mode(wsf_sel),
	.slave_1mb(slave_1mb_r),
	.asylum_mode(game_id == leland_board_pkg::GAME_ASYLUM),
	.rom_addr(slave_rom_addr_a),
	.rom_data(slave_rom_data_r),

	.vp_req(vp_req_sa),
	.vp_rd(vp_rd_sa),
	.vp_trans(vp_trans_sa),
	.vp_addr(vp_addr_sa),
	.vp_data(vp_data_sa),
	.vp_pop(vp_pop_s),
	.vp_rdata(vp_rdata_s),

	.wram_addr(wram_addr_sa),
	.wram_din(wram_din_sa),
	.wram_we(wram_we_sa),
	.wram_dout(wram_dout_s),

	.slave_int_req(slave_int_req),
	.nmi_n(slave_nmi_n),
	.slave_halt_n(slave_halt_n_a),

	.raster_line(raster_line),

	.rom_req  (slave_rom_req_a),
	.rom_stall(slave_rom_stall)
);

//------------------------------------------------------------------
// Sound board: s80x86 core + i186_periph + leland_sound_board +
// leland_dac_mixer, bundled in rtl/audio/leland_sound.sv.
//------------------------------------------------------------------
wire        sound_rom_req;
wire [19:0] sound_rom_addr_w;
reg   [7:0] sound_rom_data_r;

// Line cache for the sound CPU code fetch (rd3).
wire sound_rom_stall;
// Its misses share the SDRAM with master and slave, so caching also reduces
// their contention.
rom_line_cache #(
	.BASE       (leland_board_pkg::ADDR_SOUND_BASE),
	.ADDR_WIDTH (20),
	.INDEX_BITS (11)
) rd3_cache (
	.clk_sys      (clk_sys),
	.reset        (sdram_init),
	.sdram_ready  (sdram_ready),

	.cpu_req      (sound_rom_req),
	.cpu_addr     (sound_rom_addr_w),
	.cpu_data     (sound_rom_data_r),
	.cpu_stall    (sound_rom_stall),

	.sd_req       (sdram_rd3_req),
	.sd_addr      (sdram_rd3_addr),
	.sd_data      (sdram_rd3_data),
	.sd_ack       (sdram_rd3_ack)
);


// SIM_NO_SOUND stubs out the 80186 (too slow to simulate) for master/slave-only runs.
`ifndef SIM_NO_SOUND
leland_sound #(
	.WSF_MIXER_PROFILE(WSF_MIXER_PROFILE),
	.CPU_PACING_PROFILE(CPU_PACING_PROFILE),
	.USE_EXTERNAL_PIT_CE(TARGET_CLOCK_PROFILE != 0)
) sound(
	.clk_sys(clk_sys),
	.reset(reset | ~cpu_release),
	.ataxx_mode(ataxx_sel),
	.wsf_mode(wsf_sel),
	.ce_8m(CE_8M),
	.ce_4m(CE_4M),

	.sound_ctrl_data(sound_ctrl_data),
	.sound_ctrl_wr(sound_ctrl_wr),
	.cmd_wr_data(sound_cmd_wr_data),
	.cmd_wr_lo(sound_cmd_wr_lo),
	.cmd_wr_hi(sound_cmd_wr_hi),
	.response_data(sound_response_data),

	.rom_req(sound_rom_req),
	.rom_addr(sound_rom_addr_w),
	.rom_data(sound_rom_data_r),
	.rom_stall(sound_rom_stall),

	.ext_req(ext_req_w),
	.ext_addr(ext_addr_w),
	.ext_data(ext_data_w),
	.ext_stall(ext_stall_w),

	.audio_out(audio_out)
);
`else
assign sound_response_data = 8'h00;
assign sound_rom_req       = 1'b0;
assign sound_rom_addr_w    = '0;
assign ext_req_w           = 1'b0;
assign ext_addr_w          = '0;
assign audio_out           = 16'h0;
`endif

//------------------------------------------------------------------
// Video system
//------------------------------------------------------------------
generate if (ASYLUM_RENDER_SNAPSHOT) begin : g_render_snapshot
 leland_render_snapshot snapshot (
  .clk(clk_sys), .hard_reset(snapshot_init), .stop(reset | ~cpu_release | snapshot_transport_fault),
  .group_active(render_group_active), .group_done(render_group_done),
  .vblank(VBlank), .video_addr(vram_addr_vid[15:0]),
  .palette_addr(pal_addr_vid), .video_data(vram_dout_vid), .palette_data(pal_dout_vid),
  .pause_cpus(snapshot_pause),
  .buses_quiet(master_bus_held && (slave_bus_held || !slave_reset_n) && seq_state==SEQ_IDLE &&
               !vp_req_m && !vp_req_s && !vram_we_cpu),
  .capture_port(snapshot_capture), .capture_addr(snapshot_capture_addr),
  .capture_data(vram_live_data), .capture_pal_addr(snapshot_capture_pal_addr),
  .capture_pal_data(pal_live_data),
  .ddr_addr(snapshot_ddr_addr), .ddr_din(snapshot_ddr_din),
  .ddr_we(snapshot_ddr_we), .ddr_rd(snapshot_ddr_rd),
  .ddr_busy(snapshot_ddr_busy), .ddr_dout(snapshot_ddr_dout), .ddr_ready(snapshot_ddr_ready),
  .valid(snapshot_valid), .fault(snapshot_fault));
end else begin : g_live_bitmap
 assign snapshot_pause=0; assign snapshot_capture=0;
 assign snapshot_capture_addr=0; assign snapshot_capture_pal_addr=0;
 assign snapshot_valid=1; assign snapshot_fault=0;
 assign vram_dout_vid=vram_live_data; assign pal_dout_vid=pal_live_data;
 assign snapshot_ddr_addr=0; assign snapshot_ddr_din=0;
 assign snapshot_ddr_rd=0; assign snapshot_ddr_we=0;
end endgenerate
leland_video video
(
	.clk_sys(clk_sys),
	.reset(reset | ~video_release), // fetch pipeline waits for the load -- see video_release/cpu_release above
	.reset_cnt(sdram_init),         // raster counters free-run
	.ce_pix(ce_pix),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),

	.vram_addr(vram_addr_vid),
	.vram_data(vram_dout_vid),

	.cram_addr(cram_addr_vid),
	.cram_data(cram_dout_vid),

	.ataxx_mode(ataxx_sel),
	.gfx_wide(gfx_wide_r),
	.qram_addr(qram_addr_vid),
	.qram_data(qram_dout_vid),
	.pal_addr(pal_addr_vid),
	.pal_data(pal_dout_vid),

	.rgb(rgb),

	.scroll_x(scroll_x_m),
	.scroll_y(scroll_y_m),
	.gfxbank(gfxbank_m),

	.sdram_rd2_req  (sdram_rd2_req_v),
	.sdram_rd2_ack  (sdram_rd2_ack & ~(repack_active | ee_active)), // boot FSMs borrow rd2; their acks are not the video's
	.sdram_rd2_addr (sdram_rd2_addr_v),
	.sdram_rd2_data (sdram_rd2_data),
	.sdram_rd2_data16(sdram_rd2_data16),
	.sdram_rd2_data16_hi(sdram_rd2_data16_hi),
	.sdram_rd2_data16_w2(sdram_rd2_data16_w2),
	.fetch_busy     (rd2_fetch_busy),
	.rbuf_count_out (rd2_rbuf_count),

	.raster_line(raster_line)
);

endmodule
