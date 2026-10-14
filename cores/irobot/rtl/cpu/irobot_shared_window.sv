`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// OUT0-controlled 6809 view of object ROM, communication RAM, and math RAM.
module irobot_shared_window (
	input logic shared_cs,input logic bus_rw,input logic[12:0]window_offset,
	input logic[7:0]bus_dout,input logic[1:0]outx,input logic[1:0]mpage,
	input logic[7:0]object_dout,input logic[7:0]comm_dout,input logic[7:0]math_dout,
	output logic[7:0]shared_dout,
	output logic[15:0]object_byte_addr,
	output logic comm_req,output logic comm_we,output logic[11:0]comm_addr,output logic[7:0]comm_din,
	output logic math_we,output logic[12:0]math_addr,output logic[7:0]math_din
);
	always_comb begin
		if(outx==0)object_byte_addr={2'b00,mpage[0],13'b0}+{3'b000,window_offset};
		else object_byte_addr=16'h4000+{1'b0,mpage,13'b0}+{3'b000,window_offset};
		comm_addr=window_offset[11:0];comm_din=bus_dout;
		math_addr=window_offset;math_din=bus_dout;
		comm_req=shared_cs&&(outx==2);comm_we=comm_req&&!bus_rw;
		math_we=shared_cs&&!bus_rw&&(outx==3);
		case(outx)
			0,1:shared_dout=object_dout;
			2:shared_dout=comm_dout;
			default:shared_dout=math_dout;
		endcase
	end
endmodule
