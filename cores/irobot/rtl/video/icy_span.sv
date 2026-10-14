`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// ICY polygon scanline writer. The left edge pixel is excluded, matching the
// board-level polygon convention exposed by the MAME behavioural model.
module icy_span (
	input  logic clk,
	input  logic reset,
	input  logic start,
	input  logic signed [9:0] x0,
	input  logic signed [9:0] x1,
	input  logic signed [9:0] y,
	input  logic [5:0] color,
	output logic busy,
	output logic done,
	output logic fb_we,
	output logic [15:0] fb_addr,
	output logic [6:0] fb_data
);
	logic signed [10:0] left_clip, right_clip;
	logic [7:0] current_x, final_x, line_y;

	always_comb begin
		if (x0 <= x1) begin
			left_clip  = {x0[9], x0};
			right_clip = {x1[9], x1};
		end else begin
			left_clip  = {x1[9], x1};
			right_clip = {x0[9], x0};
		end
		if (left_clip < 0) left_clip = 0;
		if (right_clip > 255) right_clip = 255;
	end

	always_ff @(posedge clk) begin
		done  <= 1'b0;
		fb_we <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
		end else if (start && !busy) begin
			if ((y >= 0) && (y < 232) && (left_clip < right_clip)) begin
				current_x <= left_clip[7:0] + 8'd1;
				final_x   <= right_clip[7:0];
				line_y    <= y[7:0];
				busy      <= 1'b1;
			end else begin
				done <= 1'b1;
			end
		end else if (busy) begin
			fb_we   <= 1'b1;
			fb_addr <= {line_y, current_x};
			fb_data <= {1'b0, color};
			if (current_x == final_x) begin
				busy <= 1'b0;
				done <= 1'b1;
			end else begin
				current_x <= current_x + 8'd1;
			end
		end
	end
endmodule
