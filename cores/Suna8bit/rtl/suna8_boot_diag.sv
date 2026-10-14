module suna8_boot_diag
(
	input  logic        clk,
	input  logic        timing_reset,
	input  logic        machine_reset,
	input  logic        download_active,
	input  logic        profile_valid,
	input  logic        media_initialized,
	input  logic        media_write_busy,
	input  logic        media_verify_active,
		input  logic        media_verify_failed,
		input  logic        media_bytes_dropped,
		input  logic        core_ready,
		input  logic [2:0]  profile_id,
	output logic        ce_pix,
	output logic        hblank,
	output logic        vblank,
	output logic        hsync,
	output logic        vsync,
	output logic [7:0]  video_r,
	output logic [7:0]  video_g,
	output logic [7:0]  video_b,
	output logic [31:0] frame_counter
);

	logic [8:0] pixel_x;
	logic [8:0] pixel_y;

	// This timing source is deliberately independent of the game/profile/
	// SDRAM readiness chain. A failure that keeps the game raster in reset
	// must still produce visible sync and a diagnostic colour on real MiSTer.
	suna8_raster u_diag_raster
	(
		.clk(clk),
		.reset(timing_reset),
		.ce_pix(ce_pix),
		.hblank(hblank),
		.vblank(vblank),
		.hsync(hsync),
		.vsync(vsync),
		.pixel_x(pixel_x),
		.pixel_y(pixel_y),
		.profile_id(profile_id),
		.frame_counter(frame_counter)
	);

	always_comb begin
		video_r = 8'd0;
		video_g = 8'd0;
		video_b = 8'd0;
		if (!hblank && !vblank) begin
			if (download_active) begin
				// Blue: Main is still transferring an MRA ROM node.
				video_b = 8'hff;
			end else if (!profile_valid) begin
				// Red: the fixed index-1 profile byte was not accepted.
				video_r = 8'hff;
			end else if (!media_initialized) begin
				// Magenta: external SDRAM never completed initialization.
				video_r = 8'hff;
				video_b = 8'hff;
			end else if (media_write_busy) begin
				// Yellow: the final paired SDRAM write is still draining.
				video_r = 8'hff;
				video_g = 8'hff;
			end else if (media_verify_active) begin
				// Orange: full external-SDRAM CRC readback is in progress.
				video_r = 8'hff;
				video_g = 8'h60;
			end else if (media_bytes_dropped) begin
				// Violet: the download itself lost bytes (FIFO overflow or an
				// abandoned half pair), so the image in SDRAM cannot be intact.
				video_r = 8'h80;
				video_b = 8'hff;
			end else if (media_verify_failed) begin
				// Red/white bars: stored ROM bytes do not match the host stream.
				video_r = 8'hff;
				video_g = pixel_x[5] ? 8'hff : 8'h00;
				video_b = pixel_x[5] ? 8'hff : 8'h00;
			end else if (machine_reset || !core_ready) begin
				// Cyan: media passed but the emulated machine is still reset.
				video_g = 8'hff;
				video_b = 8'hff;
			end else begin
				// Green: every boot gate is open (forced-diagnostic mode only).
				video_g = 8'hff;
			end
		end
	end

endmodule
