`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// ICY display-list dispatcher. All communication-RAM traffic remains visible
// through one request/acknowledge port and only one object engine owns it.
module icy (
	input logic clk,input logic reset,input logic start,
	output logic mem_req,output logic [10:0]mem_addr,input logic mem_ack,input logic[15:0]mem_data,
	output logic busy,output logic done,output logic malformed,
	output logic fb_we,output logic[15:0]fb_addr,output logic[6:0]fb_data
);
	logic f_req,f_ack,f_valid,f_object_done,f_busy,f_done,f_bad;
	logic[10:0]f_addr,object_addr;logic[3:0]object_type,active_type;
	logic p_req,p_ack,p_start,p_busy,p_done,p_we;logic[10:0]p_addr;logic[15:0]p_fb_addr;logic[6:0]p_fb_data;
	logic v_req,v_ack,v_start,v_busy,v_done,v_we;logic[10:0]v_addr;logic[15:0]v_fb_addr;logic[6:0]v_fb_data;
	logic g_req,g_ack,g_start,g_busy,g_done,g_we;logic[10:0]g_addr;logic[15:0]g_fb_addr;logic[6:0]g_fb_data;
	logic skip_done;
	icy_object_fetch fetch(clk,reset,start,f_req,f_addr,f_ack,mem_data,f_valid,object_type,
		object_addr,f_object_done,f_busy,f_done,f_bad);
	icy_point_object points(clk,reset,p_start,object_addr,p_req,p_addr,p_ack,mem_data,
		p_busy,p_done,p_we,p_fb_addr,p_fb_data);
	icy_vector_object vectors(clk,reset,v_start,object_addr,v_req,v_addr,v_ack,mem_data,
		v_busy,v_done,v_we,v_fb_addr,v_fb_data);
	icy_polygon_object polygons(clk,reset,g_start,object_addr,g_req,g_addr,g_ack,mem_data,
		g_busy,g_done,g_we,g_fb_addr,g_fb_data);
	always_comb begin
		mem_req=f_req;mem_addr=f_addr;f_ack=mem_ack&&(active_type==0);
		p_ack=0;v_ack=0;g_ack=0;fb_we=0;fb_addr=0;fb_data=0;
		case(active_type)
			4'h8:begin mem_req=p_req;mem_addr=p_addr;p_ack=mem_ack;fb_we=p_we;fb_addr=p_fb_addr;fb_data=p_fb_data;end
			4'hc:begin mem_req=v_req;mem_addr=v_addr;v_ack=mem_ack;fb_we=v_we;fb_addr=v_fb_addr;fb_data=v_fb_data;end
			4'h4:begin mem_req=g_req;mem_addr=g_addr;g_ack=mem_ack;fb_we=g_we;fb_addr=g_fb_addr;fb_data=g_fb_data;end
			default:begin end
		endcase
		f_object_done=skip_done|p_done|v_done|g_done;
		busy=f_busy|p_busy|v_busy|g_busy;
		done=f_done;malformed=f_bad;
	end
	always_ff @(posedge clk)begin
		p_start<=0;v_start<=0;g_start<=0;skip_done<=0;
		if(reset)active_type<=0;
		else begin
			if(f_valid)begin
				case(object_type)
					4'h8:begin active_type<=4'h8;p_start<=1;end
					4'hc:begin active_type<=4'hc;v_start<=1;end
					4'h4:begin active_type<=4'h4;g_start<=1;end
					default:begin active_type<=0;skip_done<=1;end
				endcase
			end else if(p_done|v_done|g_done)active_type<=0;
		end
	end
endmodule
