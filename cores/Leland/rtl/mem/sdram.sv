// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kevin Coleman
//
// Simple single-port SDR SDRAM controller.
//
// Designed to be a drop-in for the "simple baseline" family of MiSTer
// SDRAM controllers (C64, Amstrad, TurboGrafx16, etc.) — one 8-bit
// client, byte-addressable, auto-precharge on every R/W, single
// outstanding transaction. The one thing many of the upstream simple
// controllers leave to the core is periodic refresh; this controller
// owns refresh internally via a counter, so cores don't have to
// remember to drive a refresh pulse.
//
// Geometry default is MT48LC16M16 / AS4C16M16SA (256 Mbit, 16M x 16,
// 32 MB, 13 row / 9 col / 4 banks) — the chip most simple MiSTer
// controllers target. Override ROW_BITS / COL_BITS / BANK_BITS for
// other parts. Byte-address layout is:
//
//   addr[0]                         = byte lane (0 = low, 1 = high)
//   addr[COL_BITS:1]                = column (9 bits)
//   addr[COL_BITS+BANK_BITS:COL_BITS+1] = bank   (2 bits)
//   addr[top:COL_BITS+BANK_BITS+1]  = row    (13 bits)
//
// Client protocol:
//   - Assert rd or we for a cycle (or hold until !ready). Controller
//     captures the request when `ready` is high.
//   - `ready` drops while the transaction runs, rises again when the
//     controller is free to accept the next request. For reads, `dout`
//     is valid on the cycle `ready` re-asserts.
//
// The SDRAM DQ pin is split into sd_dq_in / sd_dq_out / sd_dq_oe to
// keep this module simulator- and vendor-neutral. A one-line top-level
// shim ties them to the physical inout pad:
//
//   assign sdram_dq = sd_dq_oe ? sd_dq_out : 16'bz;
//   assign sd_dq_in = sdram_dq;
//
// sd_clk forwarding (DDR output, etc.) is left to the top level as well
// — real MiSTer boards use an Altera altddio_out; simulators don't
// need it.

`timescale 1ns/1ps

module sdram_simple #(
	parameter int CLK_MHZ    = 100,
	parameter int ROW_BITS   = 13,
	parameter int COL_BITS   = 9,
	parameter int BANK_BITS  = 2,
	// Conservative timing defaults, safe for all MiSTer-era parts (Alliance AS4C16M16SA,
	// Winbond W9825G6KH, Micron MT48LC16M16A2) at CLK_MHZ <= 166. tRC/tRAS are handled
	// implicitly by auto-precharge on every R/W.
	parameter int CAS_LAT    = 2,   // 2 at <=100 MHz, 3 at higher
	// Extra capture delay in whole clk_sys cycles, for hardware timing experiments. The
	// default 0 is the validated CAS_LAT-only capture point; the ideal Micron sim model is
	// expected to fail with 1.
	parameter int READ_CAP_EXTRA = 0,
	parameter int TRCD_NS    = 18,
	parameter int TRP_NS     = 18,
	parameter int TRFC_NS    = 66,  // Micron model enforces 66; spec-safe across vendors
	parameter int TWR_NS     = 12,  // 1 CLK + 7ns; rounded up
	parameter int TREFI_NS   = 7800,
	parameter int TINIT_NS   = 100_000,
	parameter int TMRD_CYC   = 2,

	// Derived — don't override. (SystemVerilog `localparam` isn't
	// allowed in the param port list by Quartus 17's parser.)
	parameter int WORD_ADDR_W = ROW_BITS + BANK_BITS + COL_BITS,
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
	input  logic [7:0]                   din,
	output logic [7:0]                   dout,
	// Full captured 16-bit word, unmuxed by addr[0]: a word-aligned reader gets both bytes
	// from one transaction. Every read already captures the full word into rdata_reg.
	output logic [15:0]                  dout16,
	input  logic                         rd,
	input  logic                         we,
	output logic                         ready,

	// Full 16-bit word write: both bytes known up front (din = low/even
	// byte, din_hi = high/odd byte), DQM held at 2'b00 (no per-byte
	// masking at all) -- see the block comment above we_word's usage in
	// S_WRITE below for why this exists alongside the plain byte `we`.
	input  logic [7:0]                   din_hi,
	input  logic                         we_word,

	// One-cycle pulse when a real client transaction (read or write) completes, as opposed
	// to an internal refresh. `ready` toggles identically for both (refresh has priority
	// over accepting rd/we in S_IDLE), so an external arbiter cannot tell from `ready`
	// alone whether its request was accepted. Aligned with `ready` re-asserting, so `dout`
	// is valid on the same cycle.
	output logic                         req_done
);

	// --- Derived cycle counts ----------------------------------------
	// ceil(ns * MHz / 1000). +999 handles the ceiling.
	localparam int TRCD_CYC  = (TRCD_NS  * CLK_MHZ + 999) / 1000;
	localparam int TRP_CYC   = (TRP_NS   * CLK_MHZ + 999) / 1000;
	localparam int TRFC_CYC  = (TRFC_NS  * CLK_MHZ + 999) / 1000;
	localparam int TWR_CYC   = (TWR_NS   * CLK_MHZ + 999) / 1000;
	localparam int TREFI_CYC = (TREFI_NS * CLK_MHZ + 999) / 1000;
	localparam int TINIT_CYC = (TINIT_NS * CLK_MHZ + 999) / 1000;
	localparam int CNT_W     = 16;  // wide enough for tINIT at 166 MHz (~17k cycles)

	// --- SDRAM command encoding {CS,RAS,CAS,WE}, active low ----------
	localparam [3:0] CMD_NOP          = 4'b0111;
	localparam [3:0] CMD_ACTIVE       = 4'b0011;
	localparam [3:0] CMD_READ         = 4'b0101;
	localparam [3:0] CMD_WRITE        = 4'b0100;
	localparam [3:0] CMD_PRECHARGE    = 4'b0010;
	localparam [3:0] CMD_AUTO_REFRESH = 4'b0001;
	localparam [3:0] CMD_LOAD_MODE    = 4'b0000;
	localparam [3:0] CMD_DESELECT     = 4'b1111;

	// --- FSM ----------------------------------------------------------
	typedef enum logic [3:0] {
		S_INIT_WAIT, S_INIT_PRE, S_INIT_REF1, S_INIT_REF2, S_INIT_MRS,
		S_IDLE,
		S_ACT, S_READ, S_WRITE,
		S_REFRESH
	} state_e;

	state_e            state;
	logic [CNT_W-1:0]  wait_cnt;
	logic [CNT_W-1:0]  refresh_cnt;
	logic              refresh_pending;

	// Latched request
	logic              rq_write;
	logic              rq_write_word; // full 16-bit word write, DQM always 00 -- see we_word
	logic              rq_byte_sel;
	logic [ROW_BITS-1:0]  rq_row;
	logic [BANK_BITS-1:0] rq_bank;
	logic [COL_BITS-1:0]  rq_col;
	logic [7:0]           rq_din;
	logic [7:0]           rq_din_hi;

	// Address field extraction from the client's byte address:
	//   addr[0] = byte lane, addr[COL_BITS:1] = column,
	//   addr[COL_BITS+BANK_BITS:COL_BITS+1] = bank, addr[top:COL_BITS+BANK_BITS+1] = row
	wire                       a_byte_sel = addr[0];
	wire [COL_BITS-1:0]        a_col      = addr[1 +: COL_BITS];
	wire [BANK_BITS-1:0]       a_bank     = addr[COL_BITS + 1 +: BANK_BITS];
	wire [ROW_BITS-1:0]        a_row      = addr[COL_BITS + BANK_BITS + 1 +: ROW_BITS];

	// Mode register value: BL=1, sequential, CL parameterized, single-write.
	localparam logic [12:0] MODE_REG = {3'b000, 1'b1, 2'b00, CAS_LAT[2:0], 1'b0, 3'b000};

	// CL+1 capture pulse: command pins are registered (see bottom of
	// file), so the chip registers our READ one cycle after we drive it,
	// and DQ comes back one cycle after that. Total delay from the FSM
	// transition cycle to the sample cycle is CL + 2.
	logic [15:0] read_capture_sr;

	// =================================================================
	// Request handshake: `ready` high only in S_IDLE (and not blocked by
	// a pending refresh).
	// =================================================================
	assign ready = (state == S_IDLE) && !refresh_pending;

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
		end else begin
			if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;

			// Shift-right read-capture pulse — bit 0 triggers the DQ
			// sample (see read-data register further down).
			read_capture_sr <= {1'b0, read_capture_sr[15:1]};

			// Free-running refresh counter; set pending and reset when
			// we hit tREFI. One pending slot is enough because tREFI is
			// much larger than any single transaction.
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
					if (refresh_pending) begin
						state           <= S_REFRESH;
						wait_cnt        <= TRFC_CYC[CNT_W-1:0] - 1'b1;
						refresh_pending <= 1'b0;
					end else if (rd || we || we_word) begin
						rq_write      <= we || we_word;
						rq_write_word <= we_word;
						rq_byte_sel   <= a_byte_sel;
						rq_row        <= a_row;
						rq_bank       <= a_bank;
						rq_col        <= a_col;
						rq_din        <= din;
						rq_din_hi     <= din_hi;
						state         <= S_ACT;
						wait_cnt      <= TRCD_CYC[CNT_W-1:0] - 1'b1;
					end
				end

				S_ACT: if (wait_cnt == 0) begin
					if (rq_write) begin
						state    <= S_WRITE;
						wait_cnt <= TWR_CYC[CNT_W-1:0] + TRP_CYC[CNT_W-1:0] - 1'b1;
					end else begin
						state    <= S_READ;
						wait_cnt <= CAS_LAT[CNT_W-1:0] + READ_CAP_EXTRA[CNT_W-1:0] + TRP_CYC[CNT_W-1:0] - 1'b1;
						// The capture point is a fixed CAS_LAT-cycle offset from CMD_READ (the first cycle of
						// S_READ). Valid data sits at exactly one cycle (wait_cnt == TRP_CYC); a wider
						// two-cycle capture window was tried and captured a cycle late.
						read_capture_sr[CAS_LAT + READ_CAP_EXTRA] <= 1'b1;
					end
				end

				S_WRITE:   if (wait_cnt == 0) state <= S_IDLE;
				S_READ:    if (wait_cnt == 0) state <= S_IDLE;
				S_REFRESH: if (wait_cnt == 0) state <= S_IDLE;

				default:   state <= S_IDLE;
			endcase
		end
	end

	// req_done: registered the same way `state` transitions back to
	// S_IDLE are, so it lands on the same cycle `ready` re-asserts.
	// Fires only for S_WRITE/S_READ completing, never for S_REFRESH.
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) req_done <= 1'b0;
		else req_done <= ((state == S_WRITE) || (state == S_READ)) && (wait_cnt == 0);
	end

	// =================================================================
	// Read data: capture the 16-bit word from DQ at the CL-offset cycle, then mux the
	// selected byte to `dout`.
	logic [15:0] rdata_reg;
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) rdata_reg <= '0;
		else if (read_capture_sr[0]) rdata_reg <= sd_dq_in;
	end
	assign dout   = rq_byte_sel ? rdata_reg[15:8] : rdata_reg[7:0];
	assign dout16 = rdata_reg;

	// =================================================================
	// Combinational next-command / address / data (drives *_nxt, registered to the pins
	// below so the chip's sample point is stable for a full cycle).
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
				cmd_nxt    = CMD_DESELECT;
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

			S_ACT: begin
				if (wait_cnt == TRCD_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt   = CMD_ACTIVE;
					sd_ba_nxt = rq_bank;
					sd_a_nxt  = rq_row;
				end
			end

			S_WRITE: begin
				if (wait_cnt == TWR_CYC[CNT_W-1:0] + TRP_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt              = CMD_WRITE;
					sd_ba_nxt            = rq_bank;
					sd_a_nxt             = '0;
					sd_a_nxt[COL_BITS-1:0] = rq_col;
					sd_a_nxt[10]         = 1'b1;     // auto-precharge
				end
				// Drive DQ throughout the WRITE state so the chip has
				// a stable sample window regardless of simulator delta
				// scheduling.
				if (state == S_WRITE && wait_cnt != 0) begin
					sd_dq_oe_nxt  = 1'b1;
					if (rq_write_word) begin
						// Full word write: both bytes are supplied by the caller and DQM stays 2'b00, so
						// both lanes are always written. Hardware testing showed DQM has no effect on which
						// byte lane is stored on this board, so nothing may depend on DQM masking one lane.
						sd_dq_out_nxt = {rq_din_hi, rq_din};
						sd_dqm_nxt    = 2'b00;
					end else begin
						// Single-byte write path: `din` is replicated to both byte lanes and DQM selects the
						// lane to store (DQM has no effect on some boards; see the full-word write above).
						sd_dq_out_nxt = {rq_din, rq_din};
						sd_dqm_nxt    = rq_byte_sel ? 2'b01 : 2'b10;
					end
				end
			end

			S_READ: begin
				if (wait_cnt == CAS_LAT[CNT_W-1:0] + READ_CAP_EXTRA[CNT_W-1:0] + TRP_CYC[CNT_W-1:0] - 1'b1) begin
					cmd_nxt              = CMD_READ;
					sd_ba_nxt            = rq_bank;
					sd_a_nxt             = '0;
					sd_a_nxt[COL_BITS-1:0] = rq_col;
					sd_a_nxt[10]         = 1'b1;
				end
				sd_dqm_nxt = 2'b00;
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
			sd_ba      <= '0;
			sd_a       <= '0;
			sd_dqm     <= 2'b11;
			sd_dq_out  <= '0;
			sd_dq_oe   <= 1'b0;
		end else begin
			cmd_r      <= cmd_nxt;
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

	// CKE high whenever we're out of reset — Vcc ramp gating is a
	// board-level concern and doesn't apply in sim.
	assign sd_cke = rst_n;

endmodule
