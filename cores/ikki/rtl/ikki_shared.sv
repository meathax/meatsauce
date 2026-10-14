//============================================================================
// Shared RAM C800–CFFF — true dual-port, one port per Z80.
//
// Both CPUs run off the same 4 MHz clock enable, so they can present writes to
// different addresses in the same cycle.  That needs two real write ports:
// described as two write statements over a plain array, Quartus built two
// Simple Dual Port copies and muxed their single write ports together, which
// silently dropped one of a pair of concurrent writes on hardware while
// simulation kept both (docs/AUDIT.md A7).
//
// Only a same-address collision needs arbitration: the main CPU wins the cycle
// and the sub CPU is held in WAIT.  The sub port does still read the address
// the main port is writing, and cross-port read-during-write is undefined on an
// M10K — but the stalled CPU re-reads once WAIT clears, so that cycle's value is
// never consumed.
//============================================================================
module ikki_shared
(
	input         clk,
	input         reset,

	input  [10:0] main_addr,
	input   [7:0] main_din,
	output  [7:0] main_dout,
	input         main_we,
	input         main_req,

	input  [10:0] sub_addr,
	input   [7:0] sub_din,
	output  [7:0] sub_dout,
	input         sub_we,
	input         sub_req,

	output        sub_wait
);

wire same_addr = (main_addr == sub_addr);
wire conflict  = main_req & sub_req & same_addr;

// Stall sub on any same-address collision; main wins the cycle.
assign sub_wait = conflict;

// The sub port is inhibited only for the colliding cycle, not for every cycle
// in which the main CPU happens to be writing somewhere else.
wire sub_we_eff = sub_we & ~(main_we & same_addr);

ikki_tdpram #(.ADDR_WIDTH(11), .DATA_WIDTH(8)) u_mem
(
	.clk(clk),
	.addr_a(main_addr),
	.din_a(main_din),
	.we_a(main_we),
	.dout_a(main_dout),
	.addr_b(sub_addr),
	.din_b(sub_din),
	.we_b(sub_we_eff),
	.dout_b(sub_dout)
);

wire _unused = reset;

endmodule
