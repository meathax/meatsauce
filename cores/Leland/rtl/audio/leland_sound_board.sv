// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// leland_sound_board -- board glue for the 80186 sound CPU.
//
// Sits downstream of i186_periph's system-side data bus (everything i186_periph did not
// claim as an internal register): decodes the external PCS peripheral window
// (command/response latch, PIT0/PIT1, dac9, clock-active status; leland_a.cpp
// peripheral_r/w, `select = offset >> 6`) and the whole-64K I/O-space DAC write path
// (dac_w), and passes everything else through to system RAM/ROM.
//
// Scope: the third-generation (Leland/Super Off-Road) sound board only -- six 8-bit
// DACs (indices 0-5), one 10-bit DAC (dac9, PCS select 4) and two PIT8254s (select 2/3).
//
// Bus addresses (`*_addr[19:1]`) are word addresses, with the byte lane selected by
// `bytesel`. MAME's peripheral_r/w and dac_w are 16-bit handlers whose `offset` is a
// word offset in the same units (PIT0 programming at byte address 0x20100 is word
// offset 0x80, `>>6` = select 2), so the constants below come straight from
// leland_a.cpp.
//
// clock_active[6:2] (leland_a.cpp m_clock_active, the PCS select-0 status read) is an
// edge-triggered latch, not a level follower: MAME calls set_clock_line() only on a pin
// transition event, and bit 6 (TMROUT0) only ever transitions high in this board's
// non-ALT timer configuration (i186_periph's `timer_tc_pulse` provides the repeated
// event). Bits 2-5 (PIT outputs) are approximated as rising-edge sets; a dac_w write to
// the matching index clears the bit immediately. Falling PIT edges are not modelled;
// firmware only depends on the long-run DAC-write rate.
module leland_sound_board(
	input  logic        clk,
	input  logic        reset,

	// --- CPU-side data bus (i186_periph's sys_data_m_* pass-through) ---
	input  logic [19:1] cpu_addr,
	output logic [15:0] cpu_data_in,
	input  logic [15:0] cpu_data_out,
	input  logic         cpu_access,
	output logic         cpu_ack,
	input  logic         cpu_wr_en,
	input  logic [1:0]   cpu_bytesel,
	input  logic         cpu_d_io,

	// --- external PCS window decode (from i186_periph's CSU, PACS/MPCS) ---
	input  logic [19:0] ext_window_base,
	input  logic         ext_window_is_mem,
	input  logic         ext_window_valid,

	// --- pass-through to system RAM/ROM for anything not claimed here ---
	output logic [19:1] mem_addr,
	input  logic [15:0] mem_data_in,
	output logic [15:0] mem_data_out,
	output logic         mem_access,
	input  logic         mem_ack,
	output logic         mem_wr_en,
	output logic [1:0]   mem_bytesel,
	output logic         mem_d_io,

	// --- timer 0 terminal-count event (i186_periph.sv's timer_tc_pulse[0]) ---
	input  logic         t0_tc_pulse,

	// --- PIT0/PIT1 counter clock enable (4 MHz; all six counters share it) ---
	input  logic         pit_ce,

	// Ataxx sound board variant (leland_a.cpp ATAXX_80186): peripherals sit in an I/O-space
	// window (not memory), there is no whole-I/O-space DAC port and no second PIT, and the
	// three DACs plus their volumes are written through PCS select 5.
	input  logic         ataxx_mode,

	// WSF variant (Indy Heat): adds the YM2151 at select 3 and the external sample DAC
	// controlled through select 5 offsets 4-7 and clocked by internal timer 1.
	input  logic         wsf_mode,
	input  logic         t1_tc_pulse,
	input  logic         t1_state,        // tmrout1 level at terminal count
	output logic         ym_we,           // 1-cycle strobe
	output logic         ym_a0,
	output logic [7:0]  ym_din,
	input  logic [7:0]  ym_dout,
	output logic         ext_req,
	output logic [18:0] ext_addr,
	input  logic [7:0]  ext_data,
	input  logic         ext_stall,

	// --- Z80-facing command/response/control seam ---
	input  logic [15:0] cmd_wr_data,
	input  logic         cmd_wr_lo, cmd_wr_hi,   // 1-cycle strobes (command_lo_w/command_hi_w)
	output logic [7:0]  response_data,           // m_sound_response
	output logic         response_wr,             // 1-cycle strobe: new response latched
	input  logic [7:0]  control_data,             // leland_80186_control_w's byte
	input  logic         control_wr,
	output logic         audiocpu_reset_n,
	output logic         audiocpu_test_n,
	output logic         int0_pin,
	output logic         int1_pin,

	// --- DAC/mixer datapath ---
	output logic [7:0]  dac_sample [0:5],
	output logic [7:0]  dac_vol    [0:5],
	output logic         dac_wr     [0:5],        // 1-cycle strobe per channel
	output logic [9:0]  dac9_sample,
	output logic         dac9_wr,

	// --- DMA seam ---
	output logic         drq0_pit_level, drq1_pit_level, // raw PIT0 out0/out1
	output logic         drq0_clear,     drq1_clear,      // 1-cycle strobes (dac_w's software clear)

	// --- debug/status ---
	output logic [6:0]  clock_active
);

// --- external PCS window hit decode ---
wire [19:1] window_base_word = ext_window_base[19:1];
wire [19:1] window_top_word  = window_base_word + 19'h180; // 0x300 bytes = 0x180 words
// Deliberately not gated on `cpu_access`: `cpu_ack`'s mux selector is built from
// local_hit/pcs2_hit/pcs3_hit, which trace back to this wire. Gating it would make the
// selector change the instant `cpu_access` drops in response to `ack`, and the
// core would see ack fall and re-assert access forever in zero time. Classifying an
// access must depend only on address/d_io, never on the access/ack handshake; only
// real bus-activity signals (`mem_access`, `pit0_access`, `do_write`, ...) may AND in
// `cpu_access`.
wire win_space_ok = ataxx_mode ? (!ext_window_is_mem && cpu_d_io) : (ext_window_is_mem && !cpu_d_io);
wire win_hit_now = ext_window_valid && win_space_ok &&
			   (cpu_addr >= window_base_word) && (cpu_addr < window_top_word);
wire [8:0] window_word_offset_now = cpu_addr - window_base_word; // 0..0x17F

// win_hit/window_word_offset are latched for the duration of a transaction.
// ext_window_base/valid (driven by i186_periph's PACS/MPCS) can change while a
// transaction is pending ack, which would flip `cpu_ack`'s mux source mid-transaction
// and close a zero-delay access<->ack loop through the core. Latched when `access`
// first asserts, the same idiom as i186_periph.sv.
reg access_prev2;
reg win_hit_latched;
reg [8:0] window_word_offset_latched;
always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		access_prev2 <= 1'b0;
		win_hit_latched <= 1'b0;
		window_word_offset_latched <= 9'b0;
	end else begin
		access_prev2 <= cpu_access;
		if (cpu_access && !access_prev2) begin
			win_hit_latched <= win_hit_now;
			window_word_offset_latched <= window_word_offset_now;
		end
	end
end
wire fresh_access = cpu_access && !access_prev2;
wire win_hit = fresh_access ? win_hit_now : win_hit_latched;
wire [8:0] window_word_offset = fresh_access ? window_word_offset_now : window_word_offset_latched;

wire [2:0] pcs_select = window_word_offset[8:6];
wire [5:0] pcs_offset = window_word_offset[5:0];

wire pcs0_hit = win_hit && (pcs_select == 3'd0); // clock-active status
wire pcs1_hit = win_hit && (pcs_select == 3'd1); // command(read)/response(write) latch
wire pcs2_hit = win_hit && (pcs_select == 3'd2); // PIT0
wire pcs3_hit = win_hit && (pcs_select == 3'd3) && !ataxx_mode; // PIT1 (absent on Ataxx)
wire ym_hit   = win_hit && (pcs_select == 3'd3) && wsf_mode;
wire pcs4_hit = win_hit && (pcs_select == 3'd4); // dac9 (word-write only)
wire pcs5_hit = win_hit && (pcs_select == 3'd5); // Ataxx DAC control (ataxx_dac_control_w)
// Outside Ataxx mode select 5 falls through to the "unimplemented read returns 0xFFFF,
// write ignored" default below, like leland_a.cpp's `m_type <= TYPE_REDLINE` guard.

// Any PCS-window hit that is not PIT0/PIT1 (pcs0/1/4 and the pcs5/select-6/7
// fallthrough) is serviced locally through the registered `local_ack` below.
wire local_reg_hit = win_hit && !pcs2_hit && !pcs3_hit;

// --- I/O-space dac_w hit decode (whole 64K word-addressed io space) ---
// Not gated on cpu_access, like win_hit_now; cpu_d_io is stable for the whole
// transaction, so no latch is needed.
wire io_hit = cpu_d_io && !ataxx_mode;
// cpu_addr is a WORD address ([19:1], bit0 implicit); io space's word
// offset equals cpu_addr directly (base 0), so "offset & 7" reads
// cpu_addr's three LSBs starting at bit 1, and "offset & 0x60" (bits
// [6:5] of the word offset) reads cpu_addr[7:6].
wire [2:0] dac_index  = cpu_addr[3:1];       // offset & 7
wire [1:0] drq_region = cpu_addr[7:6];       // offset & 0x60, bits [6:5]
wire wr_lo = cpu_bytesel[0]; // ACCESSING_BITS_0_7  (low byte lane or word)
wire wr_hi = cpu_bytesel[1]; // ACCESSING_BITS_8_15 (high byte lane or word)

wire claimed_hit = io_hit || win_hit;

// --- ack (same "hold while access asserted" idiom as i186_periph.sv /
// kf8253_leland_bus.sv, needed so a multi-cycle-held `access` from the
// caller can't re-trigger the write side effect a second time) ---
reg local_ack;
wire local_hit = io_hit || local_reg_hit;
wire do_write = local_hit && cpu_access && !local_ack && cpu_wr_en;

logic pit0_access, pit0_ack; logic [15:0] pit0_data_out;
logic pit1_access, pit1_ack; logic [15:0] pit1_data_out;
assign pit0_access = pcs2_hit && cpu_access;
assign pit1_access = pcs3_hit && cpu_access;

// No branch may ack in the same cycle `access` first asserts: the s80x86 core drops
// its `access` combinationally when `ack` arrives (`m_access = ... & ~m_ack`), so a
// same-cycle ack would close a zero-delay access<->ack loop. Every branch below is
// either a registered ack (`local_ack`/`pit0_ack`/`pit1_ack`) or the caller-owned
// `mem_ack` for passthrough.
assign cpu_ack = local_hit ? local_ack :
				  pcs2_hit  ? pit0_ack  :
				  pcs3_hit  ? pit1_ack  :
				  mem_ack;

assign mem_addr    = cpu_addr;
assign mem_data_out = cpu_data_out;
assign mem_access  = cpu_access && !claimed_hit;
assign mem_wr_en   = cpu_wr_en;
assign mem_bytesel = cpu_bytesel;
assign mem_d_io    = cpu_d_io;

// --- registers ---
reg [15:0] sound_command; // written by cmd_wr_lo/hi (Z80 side), read at pcs1
reg [7:0]  sound_response;

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		sound_command  <= 16'h0000;
		sound_response <= 8'h00;
		response_wr    <= 1'b0;
	end else begin
		response_wr <= 1'b0;
		if (cmd_wr_lo) sound_command[7:0]  <= cmd_wr_data[7:0];
		if (cmd_wr_hi) sound_command[15:8] <= cmd_wr_data[15:8];
		if (do_write && pcs1_hit) begin
			sound_response <= cpu_data_out[7:0];
			response_wr    <= 1'b1;
		end
	end
end
assign response_data = sound_response;

// --- control register (/RESET, /TEST, INT0, INT1 -- leland_80186_control_w) ---
always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		audiocpu_reset_n <= 1'b1; // F8 bit7 releases local reset; the parent still holds global/ROM reset.
		audiocpu_test_n  <= 1'b1;
		int0_pin         <= 1'b0;
		int1_pin         <= 1'b0;
	end else if (control_wr) begin
		audiocpu_reset_n <= control_data[7];
		audiocpu_test_n  <= control_data[4];
		int0_pin         <= control_data[5];
		int1_pin         <= control_data[3];
	end
end

// --- PIT0/PIT1 (KF8253) ---
logic pit0_c0_out, pit0_c1_out, pit0_c2_out;
logic pit1_c0_out, pit1_c1_out, pit1_c2_out;

kf8253_leland_bus u_pit0(
	.clk(clk), .reset(reset),
	.local_addr(pcs_offset[1:0]), .data_in(cpu_data_out), .data_out(pit0_data_out),
	.access(pit0_access), .ack(pit0_ack), .wr_en(cpu_wr_en), .bytesel(cpu_bytesel),
	.counter_0_clock(pit_ce), .counter_0_gate(1'b1), .counter_0_out(pit0_c0_out),
	.counter_1_clock(pit_ce), .counter_1_gate(1'b1), .counter_1_out(pit0_c1_out),
	.counter_2_clock(pit_ce), .counter_2_gate(1'b1), .counter_2_out(pit0_c2_out));

kf8253_leland_bus u_pit1(
	.clk(clk), .reset(reset),
	.local_addr(pcs_offset[1:0]), .data_in(cpu_data_out), .data_out(pit1_data_out),
	.access(pit1_access), .ack(pit1_ack), .wr_en(cpu_wr_en), .bytesel(cpu_bytesel),
	.counter_0_clock(pit_ce), .counter_0_gate(1'b1), .counter_0_out(pit1_c0_out),
	.counter_1_clock(pit_ce), .counter_1_gate(1'b1), .counter_1_out(pit1_c1_out),
	.counter_2_clock(pit_ce), .counter_2_gate(1'b1), .counter_2_out(pit1_c2_out));

assign drq0_pit_level = pit0_c0_out;
assign drq1_pit_level = pit0_c1_out;

// --- clock_active status (select-0 read; bits [1:0] unused -- DMA-fed
// dac 0/1 never SET a clock_active bit in leland_a.cpp, only dac_w's
// unconditional set_clock_line(dac,0) clear ever touches them, which is
// a permanent no-op since they start and stay at 0) ---
reg pit0_c2_out_d, pit1_c0_out_d, pit1_c1_out_d, pit1_c2_out_d;
wire pit0_c2_rise = pit0_c2_out & ~pit0_c2_out_d;
wire pit1_c0_rise = pit1_c0_out & ~pit1_c0_out_d;
wire pit1_c1_rise = pit1_c1_out & ~pit1_c1_out_d;
wire pit1_c2_rise = pit1_c2_out & ~pit1_c2_out_d;

wire dac_write_now = do_write && io_hit && wr_lo;

// Ataxx: offset 0 -> dac 0 (+DRQ0 clear), 1 -> dac 1 (+DRQ1 clear), 2 -> dac 2, 3 -> volumes
wire ax_wr   = ataxx_mode && do_write && pcs5_hit && wr_lo;
wire ax_dac0 = ax_wr && (pcs_offset[4:0] == 5'd0);
wire ax_dac1 = ax_wr && (pcs_offset[4:0] == 5'd1);
wire ax_dac2 = ax_wr && (pcs_offset[4:0] == 5'd2);
wire ax_vol  = ax_wr && (pcs_offset[4:0] == 5'd3);
wire ym_wr_now = do_write && ym_hit && wr_lo;

// Ataxx offsets 4-7 (WSF only): external DAC enable, disable, start and stop in 16-byte
// units. A byte write merges into the 16-bit register like MAME's COMBINE_DATA.
wire ext_wr   = wsf_mode && do_write && pcs5_hit;
wire [15:0] ext_merge_mask = (cpu_bytesel == 2'b11) ? 16'hFFFF : (cpu_bytesel == 2'b10) ? 16'hFF00 : 16'h00FF;

reg        ext_active;
reg [19:0] ext_start, ext_stop;
reg        ext_req_r;
reg [18:0] ext_addr_r;
wire       ext_done = ext_req_r && !ext_stall;
wire       ext_trigger = wsf_mode && t1_tc_pulse && t1_state && ext_active && (ext_start < ext_stop) && !ext_req_r;
assign ext_req  = ext_req_r;
assign ext_addr = ext_addr_r;

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		ext_req_r  <= 1'b0;
		ext_addr_r <= 19'h0;
	end else if (ext_trigger) begin
		ext_req_r  <= 1'b1;
		ext_addr_r <= ext_start[18:0];
	end else if (ext_done) begin
		ext_req_r  <= 1'b0;
	end
end

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		ym_we  <= 1'b0;
		ym_a0  <= 1'b0;
		ym_din <= 8'h00;
	end else begin
		ym_we <= ym_wr_now;
		if (ym_wr_now) begin
			ym_a0  <= pcs_offset[0];
			ym_din <= cpu_data_out[7:0];
		end
	end
end

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		ext_active <= 1'b0;
		ext_start  <= 20'h0;
		ext_stop   <= 20'h0;
	end else begin
		if (ext_wr && pcs_offset == 6'd4) ext_active <= 1'b1;
		if (ext_wr && pcs_offset == 6'd5) ext_active <= 1'b0;
		if (ext_wr && pcs_offset == 6'd6)
			ext_start <= {(ext_start[19:4] & ~ext_merge_mask) | (cpu_data_out & ext_merge_mask), 4'h0};
		if (ext_wr && pcs_offset == 6'd7)
			ext_stop <= {(ext_stop[19:4] & ~ext_merge_mask) | (cpu_data_out & ext_merge_mask), 4'h0};
		if (ext_done) ext_start <= ext_start + 20'd1;
	end
end

wire dac9_write_now = do_write && pcs4_hit && (cpu_bytesel == 2'b11); // mem_mask==0xffff, R10

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		pit0_c2_out_d <= 1'b0; pit1_c0_out_d <= 1'b0;
		pit1_c1_out_d <= 1'b0; pit1_c2_out_d <= 1'b0;
		clock_active  <= 7'b0;
	end else begin
		pit0_c2_out_d <= pit0_c2_out;
		pit1_c0_out_d <= pit1_c0_out;
		pit1_c1_out_d <= pit1_c1_out;
		pit1_c2_out_d <= pit1_c2_out;

		if (wsf_mode && t1_tc_pulse) clock_active[3] <= t1_state;
		if (pit0_c2_rise) clock_active[2] <= 1'b1;
		if (pit1_c0_rise) clock_active[3] <= 1'b1;
		if (pit1_c1_rise) clock_active[4] <= 1'b1;
		if (pit1_c2_rise) clock_active[5] <= 1'b1;
		if (t0_tc_pulse)  clock_active[6] <= 1'b1;

		// dac_w's unconditional set_clock_line(dac,0) clear -- takes
		// priority over a same-cycle set (see module header comment).
		if (dac_write_now && dac_index < 3'd6) clock_active[dac_index] <= 1'b0;
		if (ax_dac0) clock_active[0] <= 1'b0;
		if (ax_dac1) clock_active[1] <= 1'b0;
		if (ax_dac2) clock_active[2] <= 1'b0;
		if (dac9_write_now) clock_active[6] <= 1'b0;
	end
end

// --- DAC array writes (dac_w, whole I/O space) ---
genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_dac
		always_ff @(posedge clk or posedge reset) begin
			if (reset) begin
				// dac_sample is offset-binary centred at 128, so the reset value is 8'h80 (silence).
				dac_sample[gi] <= 8'h80;
				dac_wr[gi]     <= 1'b0;
			end else begin
				dac_wr[gi] <= 1'b0;
				if (dac_write_now && dac_index == gi[2:0]) begin
					dac_sample[gi] <= cpu_data_out[7:0];
					dac_wr[gi]     <= 1'b1;
				end
				if ((gi == 0 && ax_dac0) || (gi == 1 && ax_dac1) || (gi == 2 && ax_dac2)) begin
					dac_sample[gi] <= cpu_data_out[7:0];
					dac_wr[gi]     <= 1'b1;
				end
				if (gi == 3 && ext_done) begin
					dac_sample[gi] <= ext_data;
					dac_wr[gi]     <= 1'b1;
				end
			end
		end

		// Volume reset is synchronous because the WSF-dependent value cannot be
		// used as an asynchronous reset value by the target FPGA. Board reset is
		// held across clock edges before the sound CPU and mixer are released.
		always_ff @(posedge clk) begin
			if (reset) begin
				dac_vol[gi] <= (gi == 3 && wsf_mode) ? 8'hFF : 8'h00;
			end else begin
				if (ax_vol && gi == 0) dac_vol[gi] <= {cpu_data_out[2:0], 5'b0};
				if (ax_vol && gi == 1) dac_vol[gi] <= {cpu_data_out[5:3], 5'b0};
				if (ax_vol && gi == 2) dac_vol[gi] <= {cpu_data_out[7:6], 6'b0};
				if (do_write && io_hit && wr_hi && dac_index == gi[2:0])
					dac_vol[gi] <= cpu_data_out[15:8];
			end
		end
	end
endgenerate

// --- DRQ software-clear strobes (dac_w's `(offset&0x60)==0x40/0x60`) ---
always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		drq0_clear <= 1'b0;
		drq1_clear <= 1'b0;
	end else begin
		drq0_clear <= (dac_write_now && (drq_region == 2'b10)) || ax_dac0;
		drq1_clear <= (dac_write_now && (drq_region == 2'b11)) || ax_dac1;
	end
end

// --- dac9 (10-bit DAC, PCS select 4, full-word writes only) ---
always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		// dac9 has no volume register of its own (leland_dac_mixer.sv: it is the 10-bit
		// sample, gain 1.0), so its reset value must be the offset-binary centre (512) to
		// be silent. A 10'h000 reset is -512 from centre: a DC step on every reset release
		// and a permanent offset that eats the negative headroom.
		dac9_sample <= 10'd512;
		dac9_wr     <= 1'b0;
	end else begin
		dac9_wr <= 1'b0;
		if (dac9_write_now) begin
			dac9_sample <= cpu_data_out[9:0];
			dac9_wr     <= 1'b1;
		end
	end
end

// --- local read mux (pcs0/1; pcs4/5 and io-space are write-only, read
// as 0xFFFF matching leland_a.cpp's fallthrough-to-default warn+0xffff) ---
reg [15:0] local_rd_val;
always_comb begin
	if (pcs0_hit)
		local_rd_val = {8'h00, ((({1'b0, clock_active}) >> 1) & 8'h3e)};
	else if (pcs1_hit)
		local_rd_val = sound_command;
	else if (ym_hit)
		local_rd_val = {8'h00, ym_dout};
	else
		local_rd_val = 16'hFFFF;
end

// (local_hit now covers pcs5/select-6-7 and io-space reads too -- see
// local_reg_hit's definition above -- so there is no remaining
// claimed-but-not-local case to special-case here.)
assign cpu_data_in = local_hit ? local_rd_val :
					  pcs2_hit ? pit0_data_out :
					  pcs3_hit ? pit1_data_out :
					  mem_data_in;

always_ff @(posedge clk or posedge reset) begin
	if (reset) local_ack <= 1'b0;
	else if (local_hit && cpu_access) local_ack <= 1'b1;
	else local_ack <= 1'b0;
end

endmodule
