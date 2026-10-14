`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Executes one ICY point-object list from communication RAM.
module icy_point_object (
	input logic clk,input logic reset,input logic start,input logic [10:0] base_addr,
	output logic mem_req,output logic [10:0] mem_addr,
	input logic mem_ack,input logic [15:0] mem_data,
	output logic busy,output logic done,
	output logic fb_we,output logic [15:0] fb_addr,output logic [6:0] fb_data
);
	typedef enum logic[3:0]{IDLE,X_REQ,X_WAIT,Y_REQ,Y_WAIT,DRAW_START,DRAW_WAIT}state_t;
	state_t state;logic[10:0]ptr;logic[15:0]fixed_x,fixed_y;logic[5:0]color;
	logic point_start,point_busy,point_done;
	icy_point point(clk,reset,point_start,fixed_x,fixed_y,color,
		point_busy,point_done,fb_we,fb_addr,fb_data);
	always_ff @(posedge clk)begin
		mem_req<=0;point_start<=0;done<=0;
		if(reset)begin state<=IDLE;busy<=0;ptr<=0;end
		else case(state)
			IDLE:if(start)begin ptr<=base_addr;busy<=1;state<=X_REQ;end
			X_REQ:begin mem_addr<=ptr;mem_req<=1;state<=X_WAIT;end
			X_WAIT:if(mem_ack)begin
				if(mem_data==16'hffff)begin busy<=0;done<=1;state<=IDLE;end
				else begin fixed_x<=mem_data;state<=Y_REQ;end
			end
			Y_REQ:begin mem_addr<=ptr+11'd1;mem_req<=1;state<=Y_WAIT;end
			Y_WAIT:if(mem_ack)begin fixed_y<=mem_data;color<=mem_data[5:0];state<=DRAW_START;end
			DRAW_START:if(!point_busy)begin point_start<=1;state<=DRAW_WAIT;end
			DRAW_WAIT:if(point_done)begin ptr<=ptr+11'd2;state<=X_REQ;end
			default:state<=IDLE;
		endcase
	end
endmodule
