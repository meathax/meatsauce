`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// I, Robot mathbox micro-address sequencer and 16-entry return stack.
module mathbox_sequencer (
	input logic clk,
	input logic reset,
	input logic start,
	input logic step,
	input logic [2:0] jump_type,
	input logic [9:0] jump_address,
	input logic carry,
	input logic zero_result,
	input logic negative,
	output logic [9:0] pc
);
	logic [9:0] stack[0:15];
	logic [3:0] sp;
	logic take;
	always_comb begin
		case(jump_type)
			3'd0: take=0;
			3'd1: take=carry;
			3'd2: take=zero_result;
			3'd3: take=!negative;
			3'd4: take=negative;
			default: take=1;
		endcase
	end
	always_ff @(posedge clk) begin
		if(reset || start) begin pc<=0;sp<=0; end
		else if(step) begin
			case(jump_type)
				3'd6: begin stack[sp]<=pc+1'd1;sp<=sp+1'd1;pc<=jump_address;end
				3'd7: begin sp<=sp-1'd1;pc<=stack[sp-1'd1];end
				default: pc<=take?jump_address:pc+1'd1;
			endcase
		end
	end
endmodule
