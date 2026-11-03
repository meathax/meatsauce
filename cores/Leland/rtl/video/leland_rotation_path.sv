// SPDX-License-Identifier: GPL-3.0-or-later
// Asylum presentation rotation around the unchanged Template screen_rotate.
// Rotation modes are 0=270, 1=90, 2=normal, 3=180. The two quarter turns use
// the donor's transposed 3:4 framebuffer; 180 uses its no_rotate+flip path.
module leland_rotation_path (
	input             reset,
	input             clk_video,
	input             ce_pixel,
	input      [23:0] rgb,
	input             hsync,
	input             vsync,
	input             de,
	input             asylum_game,
	input             direct_video,
	input       [1:0] orientation,
	input             stream_busy,
	input             fb_vbl,
	input             fb_ll,
	input             ddram_busy,
	input             write_queue_empty,
	input             transport_fault,

	output            video_rotated,
	output            rotation_active,
	output            fb_en,
	output      [4:0] fb_format,
	output     [11:0] fb_width,
	output     [11:0] fb_height,
	output     [31:0] fb_base,
	output     [13:0] fb_stride,
	output            fb_force_blank,

	output            rot_ddram_clk,
	output      [7:0] rot_burstcnt,
	output     [28:0] rot_addr,
	output     [63:0] rot_din,
	output       [7:0] rot_be,
	output            rot_we,
	output            rot_rd
);

wire rotate_requested = asylum_game && !direct_video && (orientation != 2'd2);
wire no_rotate = !asylum_game || direct_video || orientation[1];
wire rotate_ccw = (orientation == 2'd0);
wire flip = rotate_requested && (orientation == 2'd3);
wire rot_video_rotated;
wire [11:0] unused_fb_width, unused_fb_height;
wire [4:0] unused_fb_format;
wire [31:0] unused_fb_base;
wire [13:0] unused_fb_stride;
wire [7:0] unused_burstcnt, unused_be;
wire [28:0] unused_addr;
wire [63:0] unused_din;
wire unused_fb_en, unused_we, unused_rd, unused_rot_clk;

reg last_fb_vbl = 1'b0;
reg pending_fb_vbl = 1'b0;
reg delayed_fb_vbl = 1'b0;
reg last_vsync = 1'b0;
reg [3:0] config_d = 4'd0;
reg capture_frame = 1'b0;
reg frame_pending = 1'b0;
reg frame_valid = 1'b0;
wire [3:0] config_now = {asylum_game, direct_video, orientation};
wire vsync_rise = !last_vsync && vsync;
wire fb_vbl_rise = !last_fb_vbl && fb_vbl;
wire rot_ce = ce_pixel && !stream_busy;
wire rotate_reset = reset || stream_busy || (config_d != config_now);

// Delaying the framework's framebuffer-vblank edge until all retained writes
// have reached DDR prevents publication of a slot that still has pending data.
always @(posedge clk_video) begin
	if (reset) begin
		last_fb_vbl <= 1'b0;
		pending_fb_vbl <= 1'b0;
		delayed_fb_vbl <= 1'b0;
	end else begin
		last_fb_vbl <= fb_vbl;
		delayed_fb_vbl <= 1'b0;
		if (!rotate_requested || stream_busy) begin
		pending_fb_vbl <= 1'b0;
		end else if ((pending_fb_vbl || fb_vbl_rise) && write_queue_empty && !rot_we) begin
			delayed_fb_vbl <= 1'b1;
			pending_fb_vbl <= 1'b0;
		end else if (fb_vbl_rise) begin
			pending_fb_vbl <= 1'b1;
		end
	end
end

// Report a rotated image only after a captured source frame has been fully
// drained. This also blanks stale or partial data during downloads and after a
// mode change while the next complete frame arrives.
always @(posedge clk_video) begin
	config_d <= config_now;
	if (reset || stream_busy || transport_fault || (config_d != config_now) || !rotate_requested) begin
		capture_frame <= 1'b0;
		frame_pending <= 1'b0;
		frame_valid <= 1'b0;
		last_vsync <= 1'b0;
	end else begin
		if (rot_ce && vsync_rise) begin
			if (capture_frame) frame_pending <= 1'b1;
			capture_frame <= unused_fb_en;
		end
		if (rot_ce) last_vsync <= vsync;
		if (frame_pending && write_queue_empty && !rot_we && delayed_fb_vbl) begin
			frame_pending <= 1'b0;
			frame_valid <= 1'b1;
		end
	end
end

	leland_screen_rotate rotate_framebuffer (
	.RESET(rotate_reset),
	.CLK_VIDEO(clk_video),
	.CE_PIXEL(rot_ce),
	.VGA_R(rgb[23:16]),
	.VGA_G(rgb[15:8]),
	.VGA_B(rgb[7:0]),
	.VGA_HS(hsync),
	.VGA_VS(vsync),
	.VGA_DE(de),
	.rotate_ccw(rotate_ccw),
	.no_rotate(no_rotate),
	.flip(flip),
	.video_rotated(rot_video_rotated),
	.FB_EN(unused_fb_en),
	.FB_FORMAT(unused_fb_format),
	.FB_WIDTH(unused_fb_width),
	.FB_HEIGHT(unused_fb_height),
	.FB_BASE(unused_fb_base),
	.FB_STRIDE(unused_fb_stride),
	.FB_VBL(delayed_fb_vbl),
	// The 66 Hz game and HDMI scanout have independent frame boundaries.
	// Two-buffer low-latency rotation can rewrite the frame being displayed;
	// use the donor's three-buffer ownership even when the host requests LL.
	.FB_LL(1'b0),
	.DDRAM_CLK(unused_rot_clk),
	.DDRAM_BUSY(ddram_busy),
	.DDRAM_BURSTCNT(unused_burstcnt),
	.DDRAM_ADDR(unused_addr),
	.DDRAM_DIN(unused_din),
	.DDRAM_BE(unused_be),
	.DDRAM_WE(unused_we),
	.DDRAM_RD(unused_rd)
);

assign video_rotated = rotate_requested && rot_video_rotated && unused_fb_en &&
					   frame_valid && !transport_fault && !stream_busy;
assign rotation_active = rotate_requested && unused_fb_en;
assign fb_en = rotate_requested && unused_fb_en;
assign fb_format = unused_fb_format;
assign fb_width = unused_fb_width;
assign fb_height = unused_fb_height;
assign fb_base = unused_fb_base;
assign fb_stride = unused_fb_stride;
assign fb_force_blank = rotate_requested &&
						(!frame_valid || transport_fault || stream_busy);
assign rot_ddram_clk = unused_rot_clk;
assign rot_burstcnt = unused_burstcnt;
assign rot_addr = unused_addr;
assign rot_din = unused_din;
assign rot_be = unused_be;
assign rot_we = rotate_requested && unused_we;
assign rot_rd = unused_rd;

endmodule
