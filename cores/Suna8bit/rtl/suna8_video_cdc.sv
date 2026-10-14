`timescale 1ns/1ps

module suna8_video_cdc
(
	input  logic        src_clk,
	input  logic        dst_clk,
	input  logic        reset,
	input  logic        src_ce,
	input  logic [23:0] src_rgb,
	input  logic        src_hblank,
	input  logic        src_vblank,
	input  logic        src_hsync,
	input  logic        src_vsync,
	output logic        dst_ce,
	output logic [23:0] dst_rgb,
	output logic        dst_hblank,
	output logic        dst_vblank,
	output logic        dst_hsync,
	output logic        dst_vsync
);

	// `reset` (upstream: !clk_sys_locked) is asserted and released
	// asynchronously to both src_clk and dst_clk. Consuming it directly in
	// each domain risks a metastable capture of the release edge; give
	// each domain its own 2-flop synchronizer (async assert, sync
	// release), the standard MiSTer CDC reset pattern, instead.
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [1:0] src_reset_sync;
	always_ff @(posedge src_clk or posedge reset) begin
		if (reset)
			src_reset_sync <= 2'b11;
		else
			src_reset_sync <= {src_reset_sync[0], 1'b0};
	end
	wire src_reset = src_reset_sync[1];

	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [1:0] dst_reset_sync;
	always_ff @(posedge dst_clk or posedge reset) begin
		if (reset)
			dst_reset_sync <= 2'b11;
		else
			dst_reset_sync <= {dst_reset_sync[0], 1'b0};
	end
	wire dst_reset = dst_reset_sync[1];

	// Bundled-data CDC: the source bundle changes only once per 6 MHz pixel.
	// The synchronized toggle is deliberately slower than the data path, so
	// the complete bundle is stable for multiple destination clocks before capture.
	logic [27:0] sample_bus;
	logic sample_toggle;
	always_ff @(posedge src_clk) begin
		if (src_reset) begin
			sample_bus    <= '0;
			sample_toggle <= 1'b0;
		end else if (src_ce) begin
			sample_bus    <= {src_rgb, src_hblank, src_vblank,
			                  src_hsync, src_vsync};
			sample_toggle <= ~sample_toggle;
		end
	end

	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic toggle_meta;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic toggle_sync;
	logic toggle_seen;

	always_ff @(posedge dst_clk) begin
		if (dst_reset) begin
			toggle_meta <= 1'b0;
			toggle_sync <= 1'b0;
			toggle_seen <= 1'b0;
			dst_ce      <= 1'b0;
			dst_rgb     <= '0;
			dst_hblank  <= 1'b1;
			dst_vblank  <= 1'b1;
			dst_hsync   <= 1'b0;
			dst_vsync   <= 1'b0;
		end else begin
			toggle_meta <= sample_toggle;
			toggle_sync <= toggle_meta;
			dst_ce      <= 1'b0;
			if (toggle_sync != toggle_seen) begin
				toggle_seen <= toggle_sync;
				dst_ce      <= 1'b1;
				dst_rgb     <= sample_bus[27:4];
				dst_hblank  <= sample_bus[3];
				dst_vblank  <= sample_bus[2];
				dst_hsync   <= sample_bus[1];
				dst_vsync   <= sample_bus[0];
			end
		end
	end

endmodule
