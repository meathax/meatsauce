// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Generic True Dual-Port Block RAM
//  Used for: Video RAM (128 KB), Color RAM (1 KB), work RAM, etc.
//============================================================================

module leland_dpram #(
	parameter ADDR_WIDTH = 17,
	parameter DATA_WIDTH = 8
)(
	input                    clk,

	// Port A (typically CPU write)
	input  [ADDR_WIDTH-1:0]  addr_a,
	input  [DATA_WIDTH-1:0]  din_a,
	input                    we_a,
	output reg [DATA_WIDTH-1:0] dout_a,

	// Port B (typically video read)
	input  [ADDR_WIDTH-1:0]  addr_b,
	input  [DATA_WIDTH-1:0]  din_b,
	input                    we_b,
	output reg [DATA_WIDTH-1:0] dout_b
);

// Reads always return the old data (no write forwarding), which is the native M10K
// behaviour and matches what Quartus infers for mixed-port read-during-write.
reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

always @(posedge clk) begin
	dout_a <= mem[addr_a];
	if (we_a) mem[addr_a] <= din_a;
end

always @(posedge clk)
begin
	dout_b <= mem[addr_b];
end

endmodule
