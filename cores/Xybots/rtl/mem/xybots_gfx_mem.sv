`timescale 1ns/1ps
//============================================================================
//  Xybots graphics memory subsystem — arbitrates the two SDRAM read clients
//  plus the loader write port onto the single-port `xybots_sdram` controller.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_gfx_mem.sv`
//  (GPL-3.0-or-later); see NOTICE.md.  Reduced to Xybots' two clients.
//
//  ---- clients and priority ------------------------------------------------
//    MO sprite row : one 8x8 4bpp row = 4 bytes -> ONE burst-2 read, assembled
//                    into 32 bits.  Region `sprites`.
//    PF tile row   : identical shape.  Region `tiles`.
//    Loader        : one 16-bit word write (address already region-offset by
//                    xybots_sdram_loader).
//
//  The loader write port beats both readers: it only runs while
//  `ioctl_download` is high, when nothing is being displayed.  The two READERS
//  ALTERNATE — when only one is asking it is served immediately; when both are
//  asking, whichever was not served last goes first.
//
//  Round-robin rather than fixed priority because BOTH readers have a hard
//  per-8-pixel deadline: PF must have the row before the tile is shifted out,
//  MO before the line buffer is displayed, so neither can be the absolute
//  loser.  Under fixed priority an MO engine issuing its 45 column fetches
//  back to back starves the playfield for the whole burst.  Alternating bounds
//  each client's wait at its own transaction plus one of the other's and does
//  not change total occupancy: 45 MO + 43 PF row fetches per 3648-clock
//  scanline is 1155 clk, 32 % of the line (1406 clk, 39 %, at the 64-column
//  ceiling).
//
//  Client addresses are flat BYTE addresses, not a {code, row} pair: on the MO
//  side the picture code has ALREADY had the vertical tile row added into it by
//  the 4D/5D LS283 pair, so "code" and "row" are not separable fields there at
//  all.
//
//  ---- client contract: "the 4 bytes at byte address A" --------------------
//  Both read clients are identical:
//
//    *_addr   byte address bits [n:2] of the wanted ROM byte, i.e. the fetch
//             returns the four bytes at {*_addr, 2'b00} .. {*_addr, 2'b11}.
//             MO: bits 18:2 of a 0x80000-byte region.  PF: 17:2 of 0x40000.
//    *_req    raise with the address and HOLD it.
//    *_valid  one-cycle pulse; `*_data` is valid in that cycle and is held
//             until the next transaction for that client completes.
//    *_data   {b3, b2, b1, b0} — b0 is the (A1,A0) = 00 ROM byte, i.e. the
//             leftmost pixel pair before h-flip.  In 16-bit terms that is
//             {word at A+2, word at A+0}, the SDRAM's own little-endian
//             packing (see xybots_sdram_loader's byte-lane note).
//             The h-flip XOR on A1/A0 (7F LS86) lives in the pixel path, which
//             is why the whole 4-byte row is fetched unconditionally.
//    then     drop `*_req`; the arbiter waits for the drop before serving
//             anything else, so one request = exactly one transaction.
//
//  A 4-byte row is 2 naturally-aligned 16-bit words, so a burst can never cross
//  an SDRAM row boundary (a row is 512 words); one ACTIVE + two CAS-pipelined
//  READs + auto-precharge cover it.
//
//  ---- latency, in clk_sys cycles (57.272727 MHz) --------------------------
//  Counted from the cycle `*_req` goes high to the cycle `*_valid` is high:
//
//    idle arbiter + idle controller, no refresh due          11 clk (192 ns)
//    ...with an AUTO_REFRESH landing on the request          17 clk (297 ns)
//    the other read client mid-transaction, worst case       31 clk (541 ns)
//
//  The video budget is one row per client per 8 displayed pixels = 64 clk_sys,
//  so the worst case leaves better than 2x headroom.  A request issued while
//  `ioctl_download` is high is NOT covered by these numbers — the loader has
//  priority and the video path is not running then.
//
//  ---- controller contract -------------------------------------------------
//  When `sd_ready` is high, pulse `sd_req` for one cycle with addr/we/blen
//  (/wdata); read data returns on `sd_rdata` with one `sd_valid` pulse per
//  word, consecutive for a burst; `sd_ready` returns high when the access
//  completes.  A request coinciding with a due refresh is latched inside the
//  controller, so the single-cycle pulse is safe.
//============================================================================

module xybots_gfx_mem #(
	parameter int AW = 24,
	// Word-address bases.  tiles is 0x20000 words (256 KB) and runs up to
	// SPR_BASE; sprites is 0x40000 words (512 KB).
	parameter logic [AW-1:0] TILE_BASE = 24'h000000,
	parameter logic [AW-1:0] SPR_BASE  = 24'h020000
)(
	input  logic          clk,
	input  logic          reset,

	// ---- MO sprite-row client (alternates with PF) ----
	input  logic          mo_req,
	input  logic [18:2]   mo_addr,       // sprites byte address, bits 18:2
	output logic          mo_valid,
	output logic [31:0]   mo_data,       // {b3,b2,b1,b0}

	// ---- PF tile-row client (alternates with MO) ----
	input  logic          pf_req,
	input  logic [17:2]   pf_addr,       // tiles byte address, bits 17:2
	output logic          pf_valid,
	output logic [31:0]   pf_data,       // {b3,b2,b1,b0}

	// ---- loader write port (16-bit word, address already in SDRAM word space) ----
	input  logic          dl_wr,
	input  logic [AW-1:0] dl_waddr,
	input  logic [15:0]   dl_wdata,
	output logic          dl_ack,

	// ---- SDRAM controller port ----
	output logic          sd_req,
	output logic [AW-1:0] sd_addr,
	output logic          sd_we,
	output logic [1:0]    sd_blen,
	output logic [15:0]   sd_wdata,
	input  logic          sd_ready,
	input  logic          sd_valid,
	input  logic [15:0]   sd_rdata
);

	typedef enum logic [1:0] { G_IDLE, G_REQ, G_WAIT, G_HOLD } gstate_t;
	gstate_t st;

	typedef enum logic [1:0] { OP_WR, OP_MO, OP_PF } op_t;
	op_t op;

	logic        wcnt;      // burst word counter (0 = low word, 1 = high word)
	logic [15:0] wlo;       // captured low word
	logic        last_mo;   // round-robin: 1 = MO was the last reader served

	// when both readers ask, the one that did NOT go last goes now
	wire take_mo = mo_req && (!pf_req || !last_mo);
	wire take_pf = pf_req && (!mo_req ||  last_mo);

	// byte address {*_addr, 2'b00} -> word address {*_addr, 1'b0}
	wire [AW-1:0] mo_wa = SPR_BASE  + {{(AW-18){1'b0}}, mo_addr, 1'b0};
	wire [AW-1:0] pf_wa = TILE_BASE + {{(AW-17){1'b0}}, pf_addr, 1'b0};

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= G_IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sd_blen <= 2'd0;
			mo_valid <= 1'b0; pf_valid <= 1'b0; dl_ack <= 1'b0; last_mo <= 1'b0;
		end else begin
			mo_valid <= 1'b0; pf_valid <= 1'b0; dl_ack <= 1'b0;
			sd_req   <= 1'b0;
			case (st)
				// -------- pick a client (write first, then alternate readers) ----
				G_IDLE: begin
					wcnt <= 1'b0;
					if (dl_wr) begin
						op <= OP_WR; sd_addr <= dl_waddr; sd_we <= 1'b1; sd_blen <= 2'd0;
						sd_wdata <= dl_wdata;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; end
					end else if (take_mo) begin
						op <= OP_MO; sd_addr <= mo_wa; sd_we <= 1'b0; sd_blen <= 2'd1;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; last_mo <= 1'b1; end
					end else if (take_pf) begin
						op <= OP_PF; sd_addr <= pf_wa; sd_we <= 1'b0; sd_blen <= 2'd1;
						if (sd_ready) begin sd_req <= 1'b1; st <= G_REQ; last_mo <= 1'b0; end
					end
				end
				// -------- req asserted for exactly this cycle --------
				G_REQ: begin
					sd_req <= 1'b0; sd_we <= 1'b0;
					st <= G_WAIT;
				end
				// -------- await completion (burst words on consecutive sd_valid) --------
				G_WAIT: begin
					if (op == OP_WR) begin
						if (sd_ready) begin dl_ack <= 1'b1; st <= G_HOLD; end
					end else if (sd_valid) begin
						if (!wcnt) begin
							wlo  <= sd_rdata;
							wcnt <= 1'b1;
						end else begin
							if (op == OP_MO) begin mo_data <= {sd_rdata, wlo}; mo_valid <= 1'b1; end
							else             begin pf_data <= {sd_rdata, wlo}; pf_valid <= 1'b1; end
							st <= G_HOLD;
						end
					end
				end
				// -------- one transaction per request: wait for req to drop --------
				G_HOLD: begin
					case (op)
						OP_WR:   if (!dl_wr)  st <= G_IDLE;
						OP_MO:   if (!mo_req) st <= G_IDLE;
						default: if (!pf_req) st <= G_IDLE;   // OP_PF
					endcase
				end
				default: st <= G_IDLE;
			endcase
		end
	end

endmodule
