`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Display-list pointer-table walker. Object engines receive one descriptor at
// a time and must acknowledge completion before the next pointer is fetched.
module icy_object_fetch (
	input  logic clk,
	input  logic reset,
	input  logic start,
	output logic mem_req,
	output logic [10:0] mem_addr,
	input  logic mem_ack,
	input  logic [15:0] mem_data,
	output logic object_valid,
	output logic [3:0] object_type,
	output logic [10:0] object_addr,
	input  logic object_done,
	output logic busy,
	output logic done,
	output logic malformed
);
	typedef enum logic [2:0] {IDLE, REQUEST, RECEIVE, PRESENT, WAIT_OBJECT} state_t;
	state_t state;
	logic [10:0] table_addr;

	always_ff @(posedge clk) begin
		mem_req <= 1'b0;
		object_valid <= 1'b0;
		done <= 1'b0;
		if (reset) begin
			state <= IDLE;
			busy <= 1'b0;
			malformed <= 1'b0;
			table_addr <= 11'd0;
		end else begin
			case (state)
				IDLE: if (start) begin
					busy <= 1'b1;
					malformed <= 1'b0;
					table_addr <= 11'd0;
					state <= REQUEST;
				end
				REQUEST: begin
					mem_req <= 1'b1;
					mem_addr <= table_addr;
					state <= RECEIVE;
				end
				RECEIVE: if (mem_ack) begin
					if (mem_data == 16'hffff) begin
						busy <= 1'b0;
						done <= 1'b1;
						state <= IDLE;
					end else begin
						object_type <= mem_data[15:12];
						object_addr <= mem_data[10:0];
						if (mem_data[15:12] != 4'h4 && mem_data[15:12] != 4'h8 && mem_data[15:12] != 4'hc)
							malformed <= 1'b1;
						state <= PRESENT;
					end
				end
				PRESENT: begin
					object_valid <= 1'b1;
					state <= WAIT_OBJECT;
				end
				WAIT_OBJECT: if (object_done) begin
					if (&table_addr) begin
						busy <= 1'b0;
						done <= 1'b1;
						malformed <= 1'b1;
						state <= IDLE;
					end else begin
						table_addr <= table_addr + 11'd1;
						state <= REQUEST;
					end
				end
				default: state <= IDLE;
			endcase
		end
	end
endmodule
