`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
/* verilator lint_off UNUSEDSIGNAL */
module icy_point (
	input logic clk,input logic reset,input logic start,
	input logic [15:0] fixed_x,input logic [15:0] fixed_y,input logic[5:0] color,
	output logic busy,output logic done,output logic fb_we,output logic[15:0] fb_addr,output logic[6:0] fb_data
);
	logic signed[15:0]px,py;
	always_comb begin
		// MAME's ROUND_TO_PIXEL receives the raw u16 object word.  The
		// coordinate is therefore unsigned before the fixed-point shift;
		// sign-extending bit 15 would incorrectly discard the right/top half
		// of the 256x232 playfield.
		px=$signed({7'b0,fixed_x[15:7]})-16'sd128;
		py=$signed({7'b0,fixed_y[15:7]})-16'sd128;
	end
	always_ff @(posedge clk) begin
		done<=0;fb_we<=0;
		if(reset)busy<=0;
		else if(start&&!busy)busy<=1;
		else if(busy)begin
			if(px>=0&&px<256&&py>=0&&py<232)begin fb_we<=1;fb_addr<={py[7:0],px[7:0]};fb_data<={1'b0,color};end
			busy<=0;done<=1;
		end
	end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
