// SPDX-License-Identifier: GPL-3.0-or-later
// Commits structural video-path changes only at a safe native-frame boundary.
`timescale 1ns/1ps

module ssv_video_mode_guard (
	input  logic       clk,
	input  logic       rst,
	input  logic       native_ce,
	input  logic       native_hsync,
	input  logic       native_vblank,

	input  logic       sd_request,
	input  logic [1:0] rotation_request,
	input  logic [1:0] aspect_request,
	input  logic [1:0] scale_request,

	output logic       sd_on,
	output logic [1:0] rotation,
	output logic [1:0] aspect,
	output logic [1:0] scale_select
);

logic native_hsync_d;
logic frame_commit_armed;
wire  native_line_start = native_ce && native_hsync && !native_hsync_d;
wire  commit_modes      = native_line_start && native_vblank &&
	                         frame_commit_armed;

// The line doubler keeps filling while bypassed. Waiting until
// the first HSync release in VBlank therefore switches a fully primed path at
// a line reference, never in active video or halfway through a sync pulse.
always_ff @(posedge clk) begin
	if (rst) begin
		native_hsync_d   <= 1'b1;
		frame_commit_armed <= 1'b1;
		sd_on            <= 1'b0;
		rotation         <= 2'd0;
		aspect           <= 2'd0;
		scale_select     <= 2'd0;
	end
	else begin
		if (native_ce) begin
			native_hsync_d <= native_hsync;
			if (!native_vblank)
				frame_commit_armed <= 1'b1;
		end

		if (commit_modes) begin
			frame_commit_armed <= 1'b0;
			sd_on          <= sd_request;
			rotation       <= rotation_request;
			aspect         <= aspect_request;
			scale_select   <= scale_request;
		end
	end
end

endmodule
