// Adapted for Batman from the Skull & Crossbones core's rtl/mem/skullxbo_sdram.sv (GPL-3.0); see NOTICE.md
`timescale 1ns/1ps
//============================================================================
//  Batman SDR-SDRAM controller for the MiSTer SDRAM module (MiSTer only).
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from the Badlands MiSTer
//  core (GPL-3.0, same author; itself from Xybots / Toobin'), after the
//  command encoding of the Arcade-Atari-system1 core's sdram.vhd.  The
//  ThunderJaws uses42.954545MHz and inverted fabric clock forwarding.
//  Target capture/refresh timing is separately qualified; no donor SDC is copied.
//
//  Part: MT48LC16M16A2 class, 4 banks x 8192 rows x 512 columns x 16, CL2,
//  READ/WRITE with auto-precharge.  Host: when `ready` is high, pulse `req`
//  for one cycle with a word address {BA, ROW, COL}, `we`, `wdata` and
//  `blen` (words - 1: 0/1/3/7).  Read words return on consecutive `valid`
//  pulses; a burst must not cross a 512-word row; writes are single words.
//  Transaction lengths from S_IDLE: burst-8 16 clk, burst-4 12, single 6,
//  refresh 5.  AUTO_REFRESH (every 7.8 us) starts only while `rfsh_ok` is
//  high.  Command, address and data pins are registered so they pack into
//  I/O registers; read data is captured one cycle later to match.
//
//  `reset` drives SDRAM_CKE and restarts the 200 us init, so it must be
//  ~pll_locked only: a game or download reset here would lose ROM data.
//  Candidate SDRAM_CLK rises at clk+T/4: PLL source -T/4 then dedicated DDIO inversion.
//  Only initialization/PLL reset may reset this controller; game reset must drain.
//============================================================================

module thunderjaws_sdram #(
	parameter int CLK_KHZ  = 42955,   // controller clock in kHz
	parameter int ROW_BITS = 13,
	parameter int COL_BITS = 9
) (
	input  logic        clk,
	input  logic        reset,        // ~pll_locked only (see header)

	// ---- host word port ----
	input  logic [ROW_BITS+COL_BITS+1:0] addr,
	input  logic [15:0] wdata,
	input  logic        we,
	input  logic [2:0]  blen,         // read burst: words-1 (0/1/3/7)
	input  logic        req,
	output logic [15:0] rdata,
	output logic        valid,
	output logic        ready,

	// ---- refresh permission: an AUTO_REFRESH may only start while high ----
	input  logic        rfsh_ok,

	// ---- SDRAM chip pins (SDRAM_CLK is driven in Arcade-Batman.sv) ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

// ---- timing, in clk cycles --------------------------------------------------
// CLK_KHZ is cycles per ms, so ns -> ns * CLK_KHZ / 1e6; this keeps products
// inside a 32-bit int.  Minimum delays round up; the refresh interval rounds down.
localparam int tINIT = (   200*CLK_KHZ +     999) /    1000;   // 200 us, ceil
localparam int tRFC  = (    66*CLK_KHZ +  999999) / 1000000;   //  66 ns, ceil
localparam int tRCD  = (    20*CLK_KHZ +  999999) / 1000000;   //  18 ns, ceil
localparam int tRP   = (    20*CLK_KHZ +  999999) / 1000000;   //  18 ns, ceil
localparam int tMRD  = (    12*CLK_KHZ +  999999) / 1000000;   //  12 ns, ceil
localparam int tREFI_RAW = (7800*CLK_KHZ) / 1000000;           // 7.8 us, floor
localparam int tREFI = (tREFI_RAW > 16) ? tREFI_RAW-16 : 1; // reserve maximum in-flight transaction
localparam logic [15:0] tREFI_LAST = 16'(tREFI - 1);
localparam int CL = 2;

localparam logic [3:0] CMD_LMR=4'b0000, CMD_REFRESH=4'b0001, CMD_PRECHARGE=4'b0010,
                       CMD_ACTIVE=4'b0011, CMD_WRITE=4'b0100, CMD_READ=4'b0101,
                       CMD_NOP=4'b0111;
// mode register: burst length 1, sequential, CL=2, standard operation, single write
localparam logic [12:0] MODE_REG = {3'b000, 1'b1, 2'b00, 3'b010, 1'b0, 3'b000};

localparam int AW     = ROW_BITS + COL_BITS + 2;
localparam int BA_HI  = AW-1,  BA_LO  = AW-2;
localparam int ROW_HI = COL_BITS + ROW_BITS - 1, ROW_LO = COL_BITS;

typedef enum logic [3:0] {
	S_INIT, S_PRE, S_TRP_I, S_REFI, S_TRC_I, S_MRD, S_TMRD,
	S_IDLE, S_ACT, S_TRCD, S_BURST, S_WR, S_RECOV, S_REF, S_TRC
} state_t;
state_t state;

logic [15:0] dly;
logic [3:0]  ref_init;
logic [15:0] rfsh_ctr;
logic        rfsh_req;

logic           we_l;
logic [15:0]    wdata_l;
logic [AW-1:0]  addr_l;
logic [2:0]     blen_l;
logic [3:0]     bcyc;             // burst cycle: READs at 0..blen_l, data at CL+1..
logic           pending;          // a captured request awaiting service

// ---- combinational command / address / DQ-OE from the single-cycle states ----
logic [3:0]  cmd;
logic [12:0] a_comb;
logic [1:0]  ba_comb;
logic        dq_oe;

// Column on A[8:0], A10 = auto-precharge, asserted only on the last read of a
// burst so the row stays open; writes always auto-precharge.  Built as one
// concatenation because iverilog mishandles part-selects inside always_comb.
wire [COL_BITS-1:0] col_cur  = addr_l[COL_BITS-1:0] + {{(COL_BITS-4){1'b0}}, bcyc};
wire                ap_last  = (bcyc == {1'b0, blen_l});
wire [12:0] col_a = {2'b00, ap_last, {(10-COL_BITS){1'b0}}, col_cur};
localparam logic [12:0] PRE_ALL = 13'h0400; // A10=1 = precharge all banks

// Continuous assigns: iverilog mishandles constant part-selects in always_*.
wire [1:0]           ba_w  = addr_l[BA_HI:BA_LO];
wire [ROW_BITS-1:0]  row_w = addr_l[ROW_HI:ROW_LO];
wire [12:0]          row_a = {{(13-ROW_BITS){1'b0}}, row_w};

always_comb begin
	cmd = CMD_NOP; a_comb = '0; ba_comb = '0; dq_oe = 1'b0;
	case (state)
		S_PRE:  begin cmd = CMD_PRECHARGE; a_comb = PRE_ALL; end
		S_REFI: cmd = CMD_REFRESH;
		S_MRD:  begin cmd = CMD_LMR; a_comb = MODE_REG; end
		S_ACT:  begin cmd = CMD_ACTIVE; ba_comb = ba_w; a_comb = row_a; end
		S_BURST: if (bcyc <= {1'b0, blen_l}) begin cmd = CMD_READ; ba_comb = ba_w; a_comb = col_a; end
		S_WR:   begin cmd = CMD_WRITE; ba_comb = ba_w; a_comb = col_a; dq_oe = 1'b1; end
		S_REF:  cmd = CMD_REFRESH;
		default: ;
	endcase
end

wire [3:0] cmd_r={SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}; logic [12:0] a_r;  logic [1:0] ba_r;
logic        dqoe_r; logic [15:0] wdata_r;

// `cmd_r` keeps its reset (a clear alone still packs into an I/O register).
// The address registers hold on NOP/REFRESH cycles, which the chip ignores.
wire cmd_has_addr = (cmd == CMD_PRECHARGE) || (cmd == CMD_LMR)
                 || (cmd == CMD_ACTIVE)    || (cmd == CMD_READ)
                 || (cmd == CMD_WRITE);

always_ff @(posedge clk) begin
	// Physical command bits remain ordinary pin registers, not a recoded FSM.
	if (reset) begin
		SDRAM_nCS<=1'b0;SDRAM_nRAS<=1'b1;SDRAM_nCAS<=1'b1;SDRAM_nWE<=1'b1;dqoe_r<=1'b0;
	end else begin
		SDRAM_nCS<=cmd[3];SDRAM_nRAS<=cmd[2];SDRAM_nCAS<=cmd[1];SDRAM_nWE<=cmd[0];dqoe_r<=dq_oe;
	end
	// Address pins are ignored for NOP/REFRESH; no enable feedback blocks IO packing.
	a_r<=a_comb;ba_r<=ba_comb;
	wdata_r <= wdata_l;
end

assign SDRAM_CKE = ~reset;

assign SDRAM_A   = a_r;
assign SDRAM_BA  = ba_r;
assign SDRAM_DQ  = dqoe_r ? wdata_r : 16'hzzzz;
assign {SDRAM_DQMH, SDRAM_DQML} = 2'b00;
// A due refresh blocks the host only once it is also permitted, so a waiting
// refresh never stalls the clients.
assign ready     = (state == S_IDLE) && !(rfsh_req && rfsh_ok) && !pending;

// helper: wait state that decrements dly, jumps to NEXT when it hits 0.
`define SXB_SDRAM_WAIT(NEXT) begin if (dly != 0) dly <= dly - 1'b1; else state <= NEXT; end

always_ff @(posedge clk) begin
	valid <= 1'b0;

	if (state != S_INIT && state != S_PRE && state != S_TRP_I &&
	    state != S_REFI && state != S_TRC_I && state != S_MRD && state != S_TMRD) begin
		if (rfsh_ctr >= tREFI_LAST) begin rfsh_ctr <= '0; rfsh_req <= 1'b1; end
		else rfsh_ctr <= rfsh_ctr + 1'b1;
	end

	if (reset) begin
		state <= S_INIT; dly <= tINIT[15:0]; ref_init <= '0;
		rfsh_ctr <= '0; rfsh_req <= 1'b0; pending <= 1'b0;
	end else begin
		case (state)
		// ---- power-up init ----
		S_INIT:  begin if (dly != 0) dly <= dly - 1'b1; else state <= S_PRE; end
		S_PRE:   begin state <= S_TRP_I; dly <= tRP[15:0]-1'b1; end
		S_TRP_I: begin if (dly != 0) dly <= dly-1'b1; else begin state <= S_REFI; ref_init <= '0; end end
		S_REFI:  begin state <= S_TRC_I; dly <= tRFC[15:0]-1'b1; end
		S_TRC_I: begin if (dly != 0) dly <= dly-1'b1;
		               else if (ref_init == 4'd7) state <= S_MRD;
		               else begin ref_init <= ref_init + 1'b1; state <= S_REFI; end end
		S_MRD:   begin state <= S_TMRD; dly <= tMRD[15:0]-1'b1; end
		S_TMRD:  `SXB_SDRAM_WAIT(S_IDLE)

		// ---- normal operation ----
		S_IDLE: begin
			// Capture an incoming request so a coincident refresh cannot drop it.
			// If the interval counter sets rfsh_req in the cycle this clears it,
			// the clear wins but S_REF is entered anyway, so no refresh is lost.
			if (req && !pending) begin
				we_l <= we; wdata_l <= wdata; addr_l <= addr; pending <= 1'b1;
				blen_l <= we ? 3'd0 : blen;          // writes are always single-word
			end
			if (rfsh_req && rfsh_ok) begin state <= S_REF; rfsh_req <= 1'b0; end
			else if (pending || req) begin pending <= 1'b0; state <= S_ACT; end
		end
		S_ACT:   begin state <= S_TRCD; dly <= tRCD[15:0]-1'b1; end
		S_TRCD:  begin if (dly != 0) dly <= dly-1'b1; else begin if(we_l)state<=S_WR;else state<=S_BURST; bcyc <= 4'd0; end end
		// Registered READ pins are accepted on the following quarter-cycle forwarded rising
		// fabric edge. CL2 drives after external READ+1+tAC; capture remains bcyc2,
		// inside that beat, then publish the registered word to the host.
		S_BURST: begin
			bcyc <= bcyc + 4'd1;
			if (bcyc >= 4'(CL)) begin rdata <= SDRAM_DQ; valid <= 1'b1; end
			if (bcyc == (4'(CL) + {1'b0, blen_l})) begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		end
		S_WR:    begin state <= S_RECOV; dly <= tRP[15:0]-1'b1; end
		S_RECOV: `SXB_SDRAM_WAIT(S_IDLE)
		S_REF:   begin state <= S_TRC; dly <= tRFC[15:0]-1'b1; end
		S_TRC:   `SXB_SDRAM_WAIT(S_IDLE)
		default: state <= S_IDLE;
		endcase
	end
end

`undef SXB_SDRAM_WAIT

endmodule
