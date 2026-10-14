`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Paired-edge ICY polygon walker. It consumes the two slope lists one segment
// at a time and delegates each visible scanline to icy_span.
module icy_polygon_object (
	input logic clk,input logic reset,input logic start,input logic [10:0] base_addr,
	output logic mem_req,output logic [10:0] mem_addr,
	input logic mem_ack,input logic [15:0] mem_data,
	output logic busy,output logic done,
	output logic fb_we,output logic [15:0] fb_addr,output logic [6:0] fb_data
);
	typedef enum logic[4:0]{IDLE,H0_REQ,H0_WAIT,H1_REQ,H1_WAIT,H2_REQ,H2_WAIT,H3_REQ,H3_WAIT,
		L_S_REQ,L_S_WAIT,L_E_REQ,L_E_WAIT,R_S_REQ,R_S_WAIT,R_E_REQ,R_E_WAIT,
		SPAN_START,SPAN_WAIT,NEXT_LINE,CHECK_LEFT,CHECK_RIGHT}state_t;
	state_t state;logic[10:0]left_ptr,right_ptr;logic signed[31:0]sx_left,sx_right;
	logic signed[15:0]slope_left,slope_right;logic signed[9:0]scan_y,end_left,end_right;
	logic[5:0]color;logic span_start,span_busy,span_done,initial_edges;
	logic signed[9:0]span_x0,span_x1;
	/* verilator lint_off UNUSEDSIGNAL */ // fixed-point fraction and overflow are intentionally discarded
	function automatic signed[9:0] coord_pixel(input logic[15:0] value);
		begin coord_pixel=$signed({1'b0,value[15:7]})-10'sd128;end
	endfunction
	function automatic signed[9:0] accum_pixel(input logic signed[31:0] value);
		logic signed[31:0] shifted;
		begin shifted=(value>>>7)-32'sd128;accum_pixel=shifted[9:0];end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */
	always_comb begin span_x0=accum_pixel(sx_left);span_x1=accum_pixel(sx_right);end
	icy_span span(clk,reset,span_start,span_x0,span_x1,scan_y,color,
		span_busy,span_done,fb_we,fb_addr,fb_data);
	always_ff @(posedge clk)begin
		mem_req<=0;span_start<=0;done<=0;
		if(reset)begin state<=IDLE;busy<=0;initial_edges<=0;end else case(state)
			IDLE:if(start)begin busy<=1;state<=H0_REQ;end
			H0_REQ:begin mem_addr<=base_addr;mem_req<=1;state<=H0_WAIT;end
			H0_WAIT:if(mem_ack)begin right_ptr<=mem_data[10:0];state<=H1_REQ;end
			H1_REQ:begin mem_addr<=base_addr+11'd1;mem_req<=1;state<=H1_WAIT;end
			H1_WAIT:if(mem_ack)begin sx_left<={16'd0,mem_data};state<=H2_REQ;end
			H2_REQ:begin mem_addr<=base_addr+11'd2;mem_req<=1;state<=H2_WAIT;end
			H2_WAIT:if(mem_ack)begin sx_right<={16'd0,mem_data};state<=H3_REQ;end
			H3_REQ:begin mem_addr<=base_addr+11'd3;mem_req<=1;state<=H3_WAIT;end
			H3_WAIT:if(mem_ack)begin
				scan_y<=coord_pixel(mem_data);color<=mem_data[5:0];
				left_ptr<=base_addr+11'd4;initial_edges<=1;state<=L_S_REQ;
			end
			L_S_REQ:begin mem_addr<=left_ptr;mem_req<=1;state<=L_S_WAIT;end
			L_S_WAIT:if(mem_ack)begin slope_left<=mem_data;state<=L_E_REQ;end
			L_E_REQ:begin mem_addr<=left_ptr+11'd1;mem_req<=1;state<=L_E_WAIT;end
			L_E_WAIT:if(mem_ack)begin
				if(slope_left==-16'sd1&&mem_data==16'hffff)begin busy<=0;done<=1;state<=IDLE;end
				else begin
					end_left<=coord_pixel(mem_data);left_ptr<=left_ptr+11'd2;
					if(initial_edges)begin initial_edges<=0;state<=R_S_REQ;end else state<=CHECK_RIGHT;
				end
			end
			R_S_REQ:begin mem_addr<=right_ptr;mem_req<=1;state<=R_S_WAIT;end
			R_S_WAIT:if(mem_ack)begin slope_right<=mem_data;state<=R_E_REQ;end
			R_E_REQ:begin mem_addr<=right_ptr+11'd1;mem_req<=1;state<=R_E_WAIT;end
			R_E_WAIT:if(mem_ack)begin
					end_right<=coord_pixel(mem_data);right_ptr<=right_ptr+11'd2;state<=SPAN_START;
			end
			SPAN_START:if(!span_busy)begin span_start<=1;state<=SPAN_WAIT;end
			SPAN_WAIT:if(span_done)state<=NEXT_LINE;
			NEXT_LINE:begin scan_y<=scan_y+10'sd1;state<=CHECK_LEFT;end
			CHECK_LEFT:if(scan_y>end_left)state<=L_S_REQ;
				else begin sx_left<=sx_left+{{16{slope_left[15]}},slope_left};state<=CHECK_RIGHT;end
			CHECK_RIGHT:if(scan_y>end_right)state<=R_S_REQ;
				else begin sx_right<=sx_right+{{16{slope_right[15]}},slope_right};state<=SPAN_START;end
			default:state<=IDLE;
		endcase
	end
endmodule
