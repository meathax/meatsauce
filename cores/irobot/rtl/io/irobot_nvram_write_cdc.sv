`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
module irobot_nvram_write_cdc (
	input logic src_clk, dst_clk, reset,
	input logic src_we,
	input logic [7:0] src_addr,
	input logic [3:0] src_data,
	output logic src_wait,
	output logic dst_we,
	output logic [7:0] dst_addr,
	output logic [3:0] dst_data
);
	logic [11:0] payload, pending_payload;
	logic pending, request, acknowledge;
	(* async_reg = "true" *) logic ack_meta, ack_sync, req_meta, req_sync;
	wire outstanding = request != ack_sync;
	assign src_wait = outstanding || pending;

	always_ff @(posedge src_clk) begin
		if(reset) begin
			payload<=0; pending_payload<=0; pending<=0; request<=0;
			ack_meta<=0; ack_sync<=0;
		end else begin
			ack_meta<=acknowledge; ack_sync<=ack_meta;
			if(!outstanding) begin
				if(pending) begin
					payload<=pending_payload; request<=~request;
					pending<=src_we;
					if(src_we) pending_payload<={src_addr,src_data};
				end else if(src_we) begin
					payload<={src_addr,src_data}; request<=~request;
				end
			end else if(src_we) begin
				assert(!pending);
				pending_payload<={src_addr,src_data}; pending<=1;
			end
		end
	end

	always_ff @(posedge dst_clk) begin
		if(reset) begin
			req_meta<=0; req_sync<=0; acknowledge<=0;
			dst_we<=0; dst_addr<=0; dst_data<=0;
		end else begin
			req_meta<=request; req_sync<=req_meta;
			dst_we<=0;
			// The consumer sees the previous dst_we on this acknowledgement edge.
			if(dst_we) acknowledge<=req_sync;
			else if(req_sync!=acknowledge) begin
				{dst_addr,dst_data}<=payload;
				dst_we<=1;
			end
		end
	end
endmodule
