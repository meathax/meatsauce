`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Executes ICY vector records. Endpoint X is formed by sequential slope
// accumulation, avoiding a wide inferred multiplier while preserving the
// documented sx + slope*(ey-sy+1) arithmetic.
module icy_vector_object (
	input logic clk,input logic reset,input logic start,input logic [10:0] base_addr,
	output logic mem_req,output logic [10:0] mem_addr,
	input logic mem_ack,input logic [15:0] mem_data,
	output logic busy,output logic done,
	output logic fb_we,output logic [15:0] fb_addr,output logic [6:0] fb_data
);
	typedef enum logic[3:0]{IDLE,W0_REQ,W0_WAIT,W1_REQ,W1_WAIT,W2_REQ,W2_WAIT,
		W3_REQ,W3_WAIT,CALC,DRAW_START,DRAW_WAIT}state_t;
	state_t state;logic[10:0]ptr;logic[15:0]ey_fixed,sy_fixed;logic signed[15:0]slope;
	logic signed[31:0]x_accum;logic signed[11:0]steps;
	logic signed[9:0]vx0,vy0,vx1,vy1;logic[5:0]color;
	logic signed[9:0]ey_pixel,sy_pixel;
	logic vector_start,vector_busy,vector_done;
	/* verilator lint_off UNUSEDSIGNAL */ // fractional and overflow bits are intentionally discarded
	function automatic signed[9:0] coord_pixel(input logic[15:0] value);
		begin coord_pixel=$signed({1'b0,value[15:7]})-10'sd128;end
	endfunction
	function automatic signed[9:0] accum_pixel(input logic signed[31:0] value);
		logic signed[31:0] shifted;
		begin shifted=(value>>>7)-32'sd128;accum_pixel=shifted[9:0];end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */
	always_comb begin
		ey_pixel=coord_pixel(ey_fixed);
		sy_pixel=coord_pixel(sy_fixed);
	end
	icy_vector vector(clk,reset,vector_start,vx0,vy0,vx1,vy1,color,
		vector_busy,vector_done,fb_we,fb_addr,fb_data);
	always_ff @(posedge clk)begin
		mem_req<=0;vector_start<=0;done<=0;
		if(reset)begin state<=IDLE;busy<=0;ptr<=0;end else case(state)
			IDLE:if(start)begin ptr<=base_addr;busy<=1;state<=W0_REQ;end
			W0_REQ:begin mem_addr<=ptr;mem_req<=1;state<=W0_WAIT;end
			W0_WAIT:if(mem_ack)begin
				if(mem_data==16'hffff)begin busy<=0;done<=1;state<=IDLE;end
				else begin ey_fixed<=mem_data;state<=W1_REQ;end
			end
			W1_REQ:begin mem_addr<=ptr+1'b1;mem_req<=1;state<=W1_WAIT;end
			W1_WAIT:if(mem_ack)begin sy_fixed<=mem_data;color<=mem_data[5:0];state<=W2_REQ;end
			W2_REQ:begin mem_addr<=ptr+11'd2;mem_req<=1;state<=W2_WAIT;end
			W2_WAIT:if(mem_ack)begin slope<=mem_data;state<=W3_REQ;end
			W3_REQ:begin mem_addr<=ptr+11'd3;mem_req<=1;state<=W3_WAIT;end
			W3_WAIT:if(mem_ack)begin
				x_accum<={16'd0,mem_data};
				steps<={{2{ey_pixel[9]}},ey_pixel}-{{2{sy_pixel[9]}},sy_pixel}+12'sd1;
				vx0<=coord_pixel(mem_data);
				vy0<=sy_pixel;vy1<=ey_pixel;state<=CALC;
			end
			CALC:if(steps>0)begin x_accum<=x_accum+{{16{slope[15]}},slope};steps<=steps-1'b1;end
				else if(steps<0)begin x_accum<=x_accum-{{16{slope[15]}},slope};steps<=steps+1'b1;end
				else begin vx1<=accum_pixel(x_accum);state<=DRAW_START;end
			DRAW_START:if(!vector_busy)begin vector_start<=1;state<=DRAW_WAIT;end
			DRAW_WAIT:if(vector_done)begin ptr<=ptr+11'd4;state<=W0_REQ;end
			default:state<=IDLE;
		endcase
	end
endmodule
