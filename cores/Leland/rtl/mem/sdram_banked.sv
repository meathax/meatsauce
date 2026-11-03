// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kevin Coleman
//
// Multi-bank open-row SDR SDRAM controller.
//
// Derived from sdram_simple (rtl/mem/sdram.sv) by adding:
//   - an explicit bank_sel input: each caller pins its traffic to one bank
//   - per-bank open-row state: one active row kept per bank
//   - a page-hit path that skips ACTIVATE when the same row is open
//   - a page-miss path: PRECHARGE bank, then ACTIVATE the new row
//   - PRECHARGE-ALL before AUTO_REFRESH
//   - tRAS honoured: S_WRITE completes TWR_CYC+1 cycles so TRCD+TWR >= tRAS
//
// Address layout (no bank field; the bank comes from bank_sel):
//   addr[0]                            = byte lane
//   addr[COL_BITS:1]                   = column (COL_BITS bits)
//   addr[COL_BITS+ROW_BITS:COL_BITS+1] = row (ROW_BITS bits)
//   ADDR_W = ROW_BITS + COL_BITS + 1
//
// The physical layer is unchanged from sdram_simple: init FSM and mode register,
// read_capture_sr scheduling and rdata_reg capture, full-word write / DQM behaviour,
// req_done semantics and registered command/address/DQ outputs.

`timescale 1ns/1ps

module sdram_banked #(
	parameter int CLK_MHZ    = 100,
	// Optional exact root frequency. Minimum wait counts use ceil(ns * Hz);
	// refresh request spacing uses floor(TREFI * Hz). The default keeps the
	// legacy CLK_MHZ formulas and their existing counter thresholds unchanged.
	parameter bit USE_RATIONAL_CLOCK = 1'b0,
	parameter integer CLK_HZ_NUMERATOR = 48_000_000,
	parameter integer CLK_HZ_DENOMINATOR = 1,
	parameter int ROW_BITS   = 13,
	parameter int COL_BITS   = 9,
	parameter int BANK_BITS  = 2,
	parameter int CAS_LAT    = 2,
	parameter int READ_CAP_EXTRA = 0,
	// Burst-read length: 1, 2, 4 or 8, matching the chip's sequential-burst mode register
	// encoding ($clog2(BURST_LEN) into the BL field, see MODE_REG). The default 1 is the
	// plain single-word read. Writes are never affected: the mode register's WBurst bit
	// (bit 9) stays 1.
	parameter int BURST_LEN  = 1,
	parameter int TRCD_NS    = 18,
	parameter int TRP_NS     = 18,
	parameter int TRAS_NS    = 42,   // new: minimum row-active time
	parameter int TRFC_NS    = 66,
	parameter int TWR_NS     = 12,
	parameter int TREFI_NS   = 7800,
	// JEDEC power-up requires >=200us of stable clock with CKE low, DQM high,
	// and NOP on the command pins before the initialization command sequence.
	parameter int TINIT_NS   = 200_000,
	parameter int TMRD_CYC   = 2,

	// Derived — no bank field in addr
	parameter int WORD_ADDR_W = ROW_BITS + COL_BITS,
	parameter int ADDR_W      = WORD_ADDR_W + 1
) (
	// --- SDRAM pins ---------------------------------------------------
	output logic                         sd_cke,
	output logic                         sd_cs_n,
	output logic                         sd_ras_n,
	output logic                         sd_cas_n,
	output logic                         sd_we_n,
	output logic [BANK_BITS-1:0]         sd_ba,
	output logic [ROW_BITS-1:0]          sd_a,
	output logic [1:0]                   sd_dqm,
	output logic [15:0]                  sd_dq_out,
	output logic                         sd_dq_oe,
	input  logic [15:0]                  sd_dq_in,

	// --- Client -------------------------------------------------------
	input  logic                         clk,
	input  logic                         rst_n,
	input  logic [ADDR_W-1:0]            addr,
	input  logic [BANK_BITS-1:0]         bank_sel,   // fixed bank for this client
	input  logic [7:0]                   din,
	output logic [7:0]                   dout,
	output logic [15:0]                  dout16,
	input  logic                         rd,
	input  logic                         we,
	output logic                         ready,

	input  logic [7:0]                   din_hi,
	input  logic                         we_word,

	output logic                         req_done,

	// Diagnostic: pulses combinationally on the S_IDLE cycle a request is accepted,
	// classified against bank_sel's open row (page_hit). leland_board gates it by the asserted
	// channel's sel_* to build per-channel page-hit-rate counters.
	output logic                         req_hit,

	// Burst-read data, valid for one cycle alongside req_done when the completed read was
	// issued with BURST_LEN>1. The width is fixed at the maximum (8) so the port shape never
	// changes; only burst_words[0 +: BURST_LEN] is meaningful. dout/dout16 remain the
	// single-word interface.
	output logic [7:0][15:0]             burst_words,

	// Burst-safe single-byte read data. dout is unsafe once BURST_LEN>1 (rdata_reg is
	// overwritten by every burst word and ends up holding the last one). bw0 is written once
	// per transaction (at burst_cnt==0), so dout_b0 is correct at any BURST_LEN; it applies
	// the same rq_byte_sel gating as dout. At BURST_LEN=1 it equals dout.
	output logic [7:0]                   dout_b0
);

	// --- Derived cycle counts ----------------------------------------
	localparam logic [63:0] NS_DENOMINATOR = 64'd1_000_000_000 * CLK_HZ_DENOMINATOR;
	localparam logic [63:0] TRCD_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TRCD_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TRCD_NS * CLK_MHZ + 999) / 1000);
	localparam logic [63:0] TRP_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TRP_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TRP_NS * CLK_MHZ + 999) / 1000);
	localparam logic [63:0] TRAS_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TRAS_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TRAS_NS * CLK_MHZ + 999) / 1000);
	localparam logic [63:0] TRFC_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TRFC_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TRFC_NS * CLK_MHZ + 999) / 1000);
	localparam logic [63:0] TWR_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TWR_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TWR_NS * CLK_MHZ + 999) / 1000);
	// The controller requests refresh when the old count equals TREFI_CYC,
	// so the event interval is threshold + 1 root edges. Rational mode uses a
	// floor bound for the interval and subtracts one for that comparator.
	localparam logic [63:0] TREFI_INTERVAL_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TREFI_NS * CLK_HZ_NUMERATOR) / NS_DENOMINATOR) :
		(((TREFI_NS * CLK_MHZ + 999) / 1000) + 1);
	localparam logic [63:0] TREFI_CYC = TREFI_INTERVAL_CYC - 1;
	localparam logic [63:0] TINIT_CYC = USE_RATIONAL_CLOCK ?
		((64'd1 * TINIT_NS * CLK_HZ_NUMERATOR + NS_DENOMINATOR - 1) / NS_DENOMINATOR) :
		((TINIT_NS * CLK_MHZ + 999) / 1000);
	localparam int CNT_W     = 16;

	// --- SDRAM command encoding {CS,RAS,CAS,WE}, active low ----------
	localparam [3:0] CMD_NOP          = 4'b0111;
	localparam [3:0] CMD_ACTIVE       = 4'b0011;
	localparam [3:0] CMD_READ         = 4'b0101;
	localparam [3:0] CMD_WRITE        = 4'b0100;
	localparam [3:0] CMD_PRECHARGE    = 4'b0010;
	localparam [3:0] CMD_AUTO_REFRESH = 4'b0001;
	localparam [3:0] CMD_LOAD_MODE    = 4'b0000;

	// --- FSM ----------------------------------------------------------
	typedef enum logic [3:0] {
		S_INIT_WAIT, S_INIT_PRE, S_INIT_REF1, S_INIT_REF2, S_INIT_MRS,
		S_IDLE,
		S_PRE,       // PRECHARGE specific bank (page-miss path)
		S_ACT,       // ACTIVATE row (cold or after miss precharge)
		S_READ,      // READ with A10=0 (hit and miss paths share this)
		S_WRITE,     // WRITE with A10=0 (hit and miss paths share this)
		S_PRE_ALL,   // PRECHARGE ALL before AUTO_REFRESH
		S_REFRESH
	} state_e;

	state_e            state;
	logic [CNT_W-1:0]  wait_cnt;
	logic [CNT_W-1:0]  refresh_cnt;
	logic              refresh_pending;

	// tRAS gate: counts down from TRAS_CYC on every ACTIVATE (any bank), tracking only the
	// most recent one. AUTO_REFRESH's PRECHARGE-ALL must not close a row before tRAS has
	// elapsed since its ACTIVATE; a cold ACTIVATE->WRITE holds a row open only
	// TRCD_CYC+TWR_CYC cycles (2 at 48 MHz), one short of TRAS_CYC (3).
	logic [CNT_W-1:0]  ras_wait_cnt;
	wire               tras_ok = (ras_wait_cnt == 0);

	// --- Per-bank open-row state ---
	// Scalar registers per bank rather than unpacked arrays: Quartus 17.0 mis-synthesises
	// dynamic-index unpacked arrays (banks whose 2-bit index has equal bits get the wrong
	// enable demux and never update).
	localparam int NBANK = 1 << BANK_BITS;

	logic [ROW_BITS-1:0] or0, or1, or2, or3; // open_row per bank 0..3
	logic                rv0, rv1, rv2, rv3;  // row_valid per bank 0..3

	// Combinational read muxes (bank_sel selects current-cycle bank).
	logic [ROW_BITS-1:0] cur_open_row;
	logic                cur_row_valid;
	always_comb begin
		case (bank_sel)
			2'd0: begin cur_open_row = or0; cur_row_valid = rv0; end
			2'd1: begin cur_open_row = or1; cur_row_valid = rv1; end
			2'd2: begin cur_open_row = or2; cur_row_valid = rv2; end
			default: begin cur_open_row = or3; cur_row_valid = rv3; end
		endcase
	end

	// Latched request
	logic              rq_write;
	logic              rq_write_word;
	logic              rq_byte_sel;
	logic [ROW_BITS-1:0]  rq_row;
	logic [BANK_BITS-1:0] rq_bank;
	logic [COL_BITS-1:0]  rq_col;
	logic [7:0]           rq_din;
	logic [7:0]           rq_din_hi;

	// Burst word index within the current read (0..BURST_LEN-1): reset at each S_READ
	// entry and incremented once per read_capture_sr[0] pulse. It is only compared against
	// constants and never used as a dynamic array index (see the per-bank open-row note
	// above); bw0..bw7 follow the same named-scalar-plus-case pattern.
	logic [3:0]           burst_cnt;
	logic [3:0]           burst_cnt_d;
	logic                 burst_capture_d;

	// Address field extraction from the client's byte address (no bank field).
	wire                       a_byte_sel = addr[0];
	wire [COL_BITS-1:0]        a_col      = addr[1 +: COL_BITS];
	wire [ROW_BITS-1:0]        a_row      = addr[COL_BITS + 1 +: ROW_BITS];

	// Page-hit/miss/cold classification (combinational, against bank_sel's row).
	wire page_hit  = cur_row_valid && (cur_open_row == a_row);
	wire page_cold = !cur_row_valid;
	// page_miss = row_valid && open_row != a_row (implicit)

	// Mode register: BL=BURST_LEN (sequential burst, bit3=0), CL parameterized. WBurst
	// (bit 9) stays 1, so writes are always single-location; only reads use the BL field.
	localparam int BURST_ORDER = $clog2(BURST_LEN);
	localparam logic [12:0] MODE_REG = {3'b000, 1'b1, 2'b00, CAS_LAT[2:0], 1'b0, BURST_ORDER[2:0]};

	// Total wait_cnt load for S_READ: CAS_LAT+READ_CAP_EXTRA cycles to the first word's
	// capture plus BURST_LEN-1 more for the rest of the burst (one word per cycle).
	localparam int READ_WAIT_LOAD = CAS_LAT + READ_CAP_EXTRA + BURST_LEN - 2;

	// Read capture shift register — preserved verbatim from sdram_simple.
	logic [15:0] read_capture_sr;

	// =================================================================
	assign ready = (state == S_IDLE) && !refresh_pending;

	// req_hit: combinational, true on the cycle a request is accepted out of S_IDLE
	// (rd/we/we_word high, no refresh pending) and it is a page hit. Mirrors the acceptance
	// condition in the S_IDLE case below; keep the two in step.
	wire req_accept = (state == S_IDLE) && !(refresh_pending && tras_ok) && (rd || we || we_word);
	assign req_hit = req_accept && page_hit;

	// =================================================================
	// Main FSM + refresh counter
	// =================================================================
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state            <= S_INIT_WAIT;
			wait_cnt         <= TINIT_CYC[CNT_W-1:0];
			refresh_cnt      <= '0;
			refresh_pending  <= 1'b0;
			read_capture_sr  <= '0;
			rq_write         <= 1'b0;
			rq_write_word    <= 1'b0;
			rq_byte_sel      <= 1'b0;
			rq_row           <= '0;
			rq_bank          <= '0;
			rq_col           <= '0;
			rq_din           <= '0;
			rq_din_hi        <= '0;
			burst_cnt        <= '0;
			or0 <= '0; or1 <= '0; or2 <= '0; or3 <= '0;
			rv0 <= 1'b0; rv1 <= 1'b0; rv2 <= 1'b0; rv3 <= 1'b0;
			ras_wait_cnt     <= '0;
		end else begin
			if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
			if (ras_wait_cnt != 0) ras_wait_cnt <= ras_wait_cnt - 1'b1;

			// Shift-right read-capture pulse — bit 0 triggers DQ sample.
			read_capture_sr <= {1'b0, read_capture_sr[15:1]};

			// Advance the burst word index on every capture pulse. This cannot collide with the
			// burst_cnt reset when a new read starts, because a new request is not started until the
			// previous one's req_done (gated on read_capture_sr) has fired.
			if (read_capture_sr[0]) burst_cnt <= burst_cnt + 4'd1;

			if (refresh_cnt == TREFI_CYC[CNT_W-1:0]) begin
				refresh_cnt     <= '0;
				refresh_pending <= 1'b1;
			end else begin
				refresh_cnt <= refresh_cnt + 1'b1;
			end

			unique case (state)
				// --- Init sequence ------------------------------------
				S_INIT_WAIT: if (wait_cnt == 0) begin
					state    <= S_INIT_PRE;
					wait_cnt <= TRP_CYC[CNT_W-1:0] - 1'b1;
				end

				S_INIT_PRE: if (wait_cnt == 0) begin
					state    <= S_INIT_REF1;
					wait_cnt <= TRFC_CYC[CNT_W-1:0] - 1'b1;
				end

				S_INIT_REF1: if (wait_cnt == 0) begin
					state    <= S_INIT_REF2;
					wait_cnt <= TRFC_CYC[CNT_W-1:0] - 1'b1;
				end

				S_INIT_REF2: if (wait_cnt == 0) begin
					state    <= S_INIT_MRS;
					wait_cnt <= TMRD_CYC[CNT_W-1:0] - 1'b1;
				end

				S_INIT_MRS: if (wait_cnt == 0) state <= S_IDLE;

				// --- Normal operation ---------------------------------
				S_IDLE: begin
					if (refresh_pending && tras_ok) begin
						// PRECHARGE ALL before AUTO_REFRESH: close every open row.
						// Gated on tras_ok -- see ras_wait_cnt comment above; do not
						// close a row before tRAS has elapsed since its ACTIVATE.
						state           <= S_PRE_ALL;
						wait_cnt        <= TRP_CYC[CNT_W-1:0] - 1'b1;
						refresh_pending <= 1'b0;
						rv0 <= 1'b0; rv1 <= 1'b0; rv2 <= 1'b0; rv3 <= 1'b0;
					end else if (rd || we || we_word) begin
						rq_write      <= we || we_word;
						rq_write_word <= we_word;
						rq_byte_sel   <= a_byte_sel;
						rq_bank       <= bank_sel;
						rq_col        <= a_col;
						rq_din        <= din;
						rq_din_hi     <= din_hi;

						if (page_hit) begin
							// Hit: go straight to READ/WRITE, no ACTIVATE.
							// row stays open; sr set here mirrors S_ACT→S_READ pattern.
							rq_row <= a_row; // not strictly needed but keep consistent
							if (we || we_word) begin
								state    <= S_WRITE;
								// TWR_CYC cycles (not TWR_CYC-1) to satisfy tRAS:
								// no TRCD was spent so tRAS window starts from the
								// original ACTIVATE; extra cycle keeps us safe.
								wait_cnt <= TWR_CYC[CNT_W-1:0];
							end else begin
								state     <= S_READ;
								wait_cnt  <= READ_WAIT_LOAD[CNT_W-1:0];
								burst_cnt <= '0;
								for (int bi = 0; bi < BURST_LEN; bi++)
									read_capture_sr[CAS_LAT + READ_CAP_EXTRA + bi] <= 1'b1;
							end
						end else begin
							// Miss or cold: latch row, go to precharge (miss) or activate (cold).
							rq_row <= a_row;
							if (page_cold) begin
								state    <= S_ACT;
								wait_cnt <= TRCD_CYC[CNT_W-1:0] - 1'b1;
							end else begin
								// Miss: precharge open row first.
								state    <= S_PRE;
								wait_cnt <= TRP_CYC[CNT_W-1:0] - 1'b1;
								case (bank_sel)
									2'd0: rv0 <= 1'b0;
									2'd1: rv1 <= 1'b0;
									2'd2: rv2 <= 1'b0;
									default: rv3 <= 1'b0;
								endcase
							end
						end
					end
				end

				// Specific-bank precharge (page-miss path).
				S_PRE: if (wait_cnt == 0) begin
					state    <= S_ACT;
					wait_cnt <= TRCD_CYC[CNT_W-1:0] - 1'b1;
				end

				S_ACT: if (wait_cnt == 0) begin
					// Update open-row state on ACTIVATE.
					case (rq_bank)
						2'd0: begin or0 <= rq_row; rv0 <= 1'b1; end
						2'd1: begin or1 <= rq_row; rv1 <= 1'b1; end
						2'd2: begin or2 <= rq_row; rv2 <= 1'b1; end
						default: begin or3 <= rq_row; rv3 <= 1'b1; end
					endcase
					// Reload tRAS gate -- this ACTIVATE just (re)opened a row;
					// block AUTO_REFRESH's PRECHARGE-ALL until tRAS elapses.
					ras_wait_cnt <= TRAS_CYC[CNT_W-1:0];
					if (rq_write) begin
						state    <= S_WRITE;
						// TWR_CYC cycles — gives tRAS margin (TRCD + TWR ≥ tRAS at 48MHz).
						wait_cnt <= TWR_CYC[CNT_W-1:0];
					end else begin
						state     <= S_READ;
						wait_cnt  <= READ_WAIT_LOAD[CNT_W-1:0];
						burst_cnt <= '0;
						for (int bi = 0; bi < BURST_LEN; bi++)
							read_capture_sr[CAS_LAT + READ_CAP_EXTRA + bi] <= 1'b1;
					end
				end

				S_WRITE:   if (wait_cnt == 0) state <= S_IDLE;
				S_READ:    if (wait_cnt == 0) state <= S_IDLE;

				// PRECHARGE ALL (before refresh) — row_valid cleared in S_IDLE above.
				S_PRE_ALL: if (wait_cnt == 0) begin
					state    <= S_REFRESH;
					wait_cnt <= TRFC_CYC[CNT_W-1:0] - 1'b1;
				end

				S_REFRESH: if (wait_cnt == 0) state <= S_IDLE;

				default:   state <= S_IDLE;
			endcase
		end
	end

	// read_done_d: read_capture_sr[0] delayed one more cycle, which is when rdata_reg's
	// registered update becomes visible. req_done's READ condition (wait_cnt==0) would
	// otherwise land on the capture cycle itself, one cycle early, and acknowledge the
	// stale rdata_reg/dout. Only req_done is delayed; wait_cnt and the READ command timing
	// are unchanged, and leland_board's in_flight gate (not `ready`) blocks a new request until
	// req_done fires.
	// For a burst, read_capture_sr[0] fires once per word, but req_done must ack once,
	// after the last word. burst_cnt is the pre-increment index, so it still reads
	// BURST_LEN-1 on the last pulse; at BURST_LEN=1 last_word_capture is
	// read_capture_sr[0].
	wire last_word_capture = read_capture_sr[0] && (burst_cnt == BURST_LEN[3:0] - 4'd1);

	logic read_done_d;
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) read_done_d <= 1'b0;
		else        read_done_d <= last_word_capture;
	end

	// req_done: fires same cycle ready re-asserts for WRITE; for READ,
	// fires one cycle after read_capture_sr[0] (see read_done_d above) so
	// the ack always captures the correctly-updated rdata_reg/dout.
	// Fires only for client transactions, not for refresh or precharge cycles.
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) req_done <= 1'b0;
		else req_done <= ((state == S_WRITE) && (wait_cnt == 0)) || read_done_d;
	end

	// =================================================================
	// Read data: do not modify the read_capture_sr scheduling or the rdata_reg capture.
	// =================================================================
	logic [15:0] rdata_reg;
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) rdata_reg <= '0;
		else if (read_capture_sr[0]) rdata_reg <= sd_dq_in;
	end
	assign dout   = rq_byte_sel ? rdata_reg[15:8] : rdata_reg[7:0];
	assign dout16 = rdata_reg;

	// =================================================================
	// Burst-word copies lag the rdata_reg pin capture by one core edge. Delay the capture pulse
	// and index with the registered data so each burst_words entry keeps its word identity.
	// This preserves read_capture_sr and rdata_reg timing while moving the index mux off the DQ
	// input path; named scalars avoid Quartus 17.0's dynamic-index bug.
	// =================================================================
	logic [15:0] bw0, bw1, bw2, bw3, bw4, bw5, bw6, bw7;
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			burst_capture_d <= 1'b0;
			burst_cnt_d     <= '0;
			bw0 <= '0; bw1 <= '0; bw2 <= '0; bw3 <= '0;
			bw4 <= '0; bw5 <= '0; bw6 <= '0; bw7 <= '0;
		end else begin
			burst_capture_d <= read_capture_sr[0];
			burst_cnt_d     <= burst_cnt;
			if (burst_capture_d) begin
				case (burst_cnt_d)
					4'd0: bw0 <= rdata_reg;
					4'd1: bw1 <= rdata_reg;
					4'd2: bw2 <= rdata_reg;
					4'd3: bw3 <= rdata_reg;
					4'd4: bw4 <= rdata_reg;
					4'd5: bw5 <= rdata_reg;
					4'd6: bw6 <= rdata_reg;
					4'd7: bw7 <= rdata_reg;
					default: ;
				endcase
			end
		end
	end
	assign dout_b0        = rq_byte_sel ? bw0[15:8] : bw0[7:0];
	assign burst_words[0] = bw0;
	assign burst_words[1] = bw1;
	assign burst_words[2] = bw2;
	assign burst_words[3] = bw3;
	assign burst_words[4] = bw4;
	assign burst_words[5] = bw5;
	assign burst_words[6] = bw6;
	assign burst_words[7] = bw7;

	// Sim-only diagnostic: a burst read must stay within one row (the chip wraps the column
	// counter within the row), so flag a request whose column is not BURST_LEN-aligned.
	// Display only, not a hard stop.
`ifndef ALTERA_RESERVED_QIS
	// ALIGN_BITS floors at 1 so the part-select below always has a valid width; the runtime
	// `BURST_LEN > 1` guard keeps it from firing at BURST_LEN=1.
	localparam int ALIGN_BITS = (BURST_ORDER > 0) ? BURST_ORDER : 1;
	// Counts misaligned bursts and prints a few examples plus a final total. A misaligned
	// burst only corrupts burst word1 (word0 is always the addressed word), and the only
	// consumer of word1 is rd2's GFXROW read, which is column-aligned by construction, so
	// firings from single-word PROM / line-cache refills are benign. A nonzero total
	// together with wrong rd2 tile graphics is the case that matters.
	integer burst_align_err_cnt = 0;
	always_ff @(posedge clk) begin
		// Qualified on req_accept so each accepted misaligned read is counted once.
		if (rst_n && (BURST_LEN > 1) && req_accept && rd
			&& (a_col[ALIGN_BITS-1:0] != '0)) begin
			burst_align_err_cnt <= burst_align_err_cnt + 1;
			if (burst_align_err_cnt < 5)
				$display("%0t: %m BURST_ALIGN_NOTE: rd col=%0d not aligned to BURST_LEN=%0d (example %0d; word0 unaffected, only word1 wraps)",
						  $time, a_col, BURST_LEN, burst_align_err_cnt);
		end
	end
	final begin
		if (burst_align_err_cnt != 0)
			$display("%m BURST_ALIGN_SUMMARY: %0d misaligned burst reads (benign unless rd2 GFXROW tile data is wrong -- only burst word1 is affected)",
					  burst_align_err_cnt);
	end
`endif

	// =================================================================
	// Combinational next-command / address / data
	// =================================================================
	logic [3:0]               cmd_nxt;
	logic [BANK_BITS-1:0]     sd_ba_nxt;
	logic [ROW_BITS-1:0]      sd_a_nxt;
	logic [1:0]               sd_dqm_nxt;
	logic [15:0]              sd_dq_out_nxt;
	logic                     sd_dq_oe_nxt;

	always_comb begin
		cmd_nxt       = CMD_NOP;
		sd_ba_nxt     = '0;
		sd_a_nxt      = '0;
		sd_dqm_nxt    = 2'b00;
		sd_dq_out_nxt = '0;
		sd_dq_oe_nxt  = 1'b0;

		unique case (state)
			S_INIT_WAIT: begin
				// Note 11 startup window: stable clock, CKE low, DQM high, NOP.
				cmd_nxt    = CMD_NOP;
				sd_dqm_nxt = 2'b11;
			end

			S_INIT_PRE: begin
				if (wait_cnt == TRP_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt     = CMD_PRECHARGE;
					sd_a_nxt    = '0;
					sd_a_nxt[10]= 1'b1;   // all banks
				end
				sd_dqm_nxt = 2'b11;
			end

			S_INIT_REF1, S_INIT_REF2: begin
				if (wait_cnt == TRFC_CYC[CNT_W-1:0] - 1'b1)
					cmd_nxt = CMD_AUTO_REFRESH;
				sd_dqm_nxt = 2'b11;
			end

			S_INIT_MRS: begin
				if (wait_cnt == TMRD_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt        = CMD_LOAD_MODE;
					sd_a_nxt[12:0] = MODE_REG;
					sd_ba_nxt      = '0;
				end
				sd_dqm_nxt = 2'b11;
			end

			// PRECHARGE specific bank (page-miss: close old row).
			// A10=0 means single-bank precharge; sd_ba selects the bank.
			S_PRE: begin
				if (wait_cnt == TRP_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt      = CMD_PRECHARGE;
					sd_ba_nxt    = rq_bank;
					sd_a_nxt     = '0;
					sd_a_nxt[10] = 1'b0;  // single bank
				end
			end

			S_ACT: begin
				if (wait_cnt == TRCD_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt   = CMD_ACTIVE;
					sd_ba_nxt = rq_bank;
					sd_a_nxt  = rq_row;
				end
			end

			S_WRITE: begin
				if (wait_cnt == TWR_CYC[CNT_W-1:0]) begin
					cmd_nxt              = CMD_WRITE;
					sd_ba_nxt            = rq_bank;
					sd_a_nxt             = '0;
					sd_a_nxt[COL_BITS-1:0] = rq_col;
					sd_a_nxt[10]         = 1'b0;     // no auto-precharge; row stays open
					// The published XS-DS module wires chip DQML/DQMH to
					// address pins A11/A12. Those pins retain their row role
					// during S_ACT; on WRITE, put the active-low byte masks here
					// as well as on the direct DQM outputs for other boards.
					sd_a_nxt[11]         = (!rq_write_word) && rq_byte_sel;
					sd_a_nxt[12]         = (!rq_write_word) && !rq_byte_sel;
				end
				// Drive DQ while WRITE in progress (wait_cnt != 0: active write cycles only).
				if (wait_cnt != 0) begin
					sd_dq_oe_nxt  = 1'b1;
					if (rq_write_word) begin
						// Full word write — DQM=00, no per-byte masking.
						// Preserved verbatim from sdram_simple (DQM has no effect
						// on this board's hardware per the proven rtl/mem/sdram.sv comment).
						sd_dq_out_nxt = {rq_din_hi, rq_din};
						sd_dqm_nxt    = 2'b00;
					end else begin
						sd_dq_out_nxt = {rq_din, rq_din};
						sd_dqm_nxt    = rq_byte_sel ? 2'b01 : 2'b10;
					end
				end
			end

			S_READ: begin
				if (wait_cnt == READ_WAIT_LOAD[CNT_W-1:0]) begin
					cmd_nxt              = CMD_READ;
					sd_ba_nxt            = rq_bank;
					sd_a_nxt             = '0;
					sd_a_nxt[COL_BITS-1:0] = rq_col;
					sd_a_nxt[10]         = 1'b0;  // no auto-precharge; row stays open
				end
				sd_dqm_nxt = 2'b00;
			end

			// PRECHARGE ALL (A10=1) — closes every open bank before AUTO_REFRESH.
			S_PRE_ALL: begin
				if (wait_cnt == TRP_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt      = CMD_PRECHARGE;
					sd_a_nxt     = '0;
					sd_a_nxt[10] = 1'b1;  // all banks
				end
			end

			S_REFRESH: begin
				if (wait_cnt == TRFC_CYC[CNT_W-1:0] - 1'b1)
					cmd_nxt = CMD_AUTO_REFRESH;
			end

			default: ;
		endcase
	end

	// --- Registered SDRAM outputs ------------------------------------
	logic [3:0] cmd_r;

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			cmd_r      <= CMD_NOP;
			sd_cke     <= 1'b0;
			sd_ba      <= '0;
			sd_a       <= '0;
			sd_dqm     <= 2'b11;
			sd_dq_out  <= '0;
			sd_dq_oe   <= 1'b0;
		end else begin
			cmd_r      <= cmd_nxt;
			// Keep CKE low for the complete startup/restart interval.  The
			// FSM observes wait_cnt==0 on the edge after the final decrement;
			// PRECHARGE is registered on the following edge, so it cannot precede
			// this CKE release.
			if ((state == S_INIT_WAIT) && (wait_cnt == 0))
				sd_cke <= 1'b1;
			sd_ba      <= sd_ba_nxt;
			sd_a       <= sd_a_nxt;
			sd_dqm     <= sd_dqm_nxt;
			sd_dq_out  <= sd_dq_out_nxt;
			sd_dq_oe   <= sd_dq_oe_nxt;
		end
	end

	assign sd_cs_n  = cmd_r[3];
	assign sd_ras_n = cmd_r[2];
	assign sd_cas_n = cmd_r[1];
	assign sd_we_n  = cmd_r[0];

endmodule
