// SPDX-License-Identifier: GPL-3.0-or-later
// Shared SSV mahjong key-matrix/select interface.
//
// Addressing and permutations follow pinned MAME 0.289 ssv.cpp.  No claim is
// made about unmodelled electrical delay or pull networks on the physical PCB.
`timescale 1ns/1ps

module ssv_mahjong_matrix (
	input  logic        clk,
	input  logic        rst,
	input  logic  [2:0] mode,
	input  logic        req,
	input  logic        we,
	input  logic [23:0] addr,
	input  logic [15:0] wdata,
	input  logic  [1:0] be,
	input  logic [23:0] rows, // four active-low six-bit rows, row0 in [5:0]
	output logic        selected,
	output logic [15:0] rdata
);

	logic [15:0] selector;
	logic read_hit, write_hit;
	logic [5:0] combined, permuted;

	always_comb begin
		read_hit = 1'b0;
		write_hit = 1'b0;
		unique case (mode)
			3'd1: begin read_hit = (addr == 24'hc00000); write_hit = (addr == 24'hc00006); end
			3'd2: begin read_hit = (addr == 24'h500000) || (addr == 24'h500002); write_hit = (addr == 24'h520000); end
			3'd3: begin read_hit = (addr == 24'h800002); write_hit = (addr == 24'h800000); end
			3'd4: begin read_hit = (addr == 24'hc0000a); write_hit = (addr == 24'hc0000e); end
			3'd5: begin read_hit = (addr == 24'h600000); write_hit = (addr == 24'h680000); end
			default: begin end
		endcase
		selected = req && ((we && write_hit) || (!we && read_hit));
		combined = 6'h3f;
		if (mode <= 3'd2) begin
			if (selector[0]) combined &= rows[5:0];
			if (selector[1]) combined &= rows[11:6];
			if (selector[2]) combined &= rows[17:12];
			if (selector[3]) combined &= rows[23:18];
			permuted = combined;
		end else begin
			if (selector[1]) combined &= (mode == 3'd5) ? rows[17:12] : rows[23:18];
			if (selector[2]) combined &= (mode == 3'd5) ? rows[11:6]  : rows[17:12];
			if (selector[3]) combined &= (mode == 3'd5) ? rows[5:0]   : rows[11:6];
			if (selector[4]) combined &= (mode == 3'd5) ? rows[23:18] : rows[5:0];
			permuted = {combined[0], combined[1], combined[2],
			            combined[3], combined[4], combined[5]};
		end
		rdata = (mode == 3'd1 || mode == 3'd2 || mode == 3'd5)
			? {8'h00, 2'b11, permuted} : {10'h3ff, permuted};
	end

	always_ff @(posedge clk) begin
		if (rst)
			selector <= 16'h0000;
		else if (req && we && write_hit) begin
			if (be[0]) selector[7:0] <= wdata[7:0];
			if (be[1]) selector[15:8] <= wdata[15:8];
		end
	end
endmodule
