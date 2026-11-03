// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer presentation path for the selected Leland raster.
//
// video_mixer keeps the RGB/sync/blank tuple aligned through the framework's
// output registers and optional VGA scandoubler. video_freak measures that
// completed tuple, applies the existing aspect-ratio selection, and reports
// the integer-scaling viewport to MiSTer.
module leland_display
(
	input             clk_video,
	input      [23:0] rgb_in,
	input             ce_pix_in,
	input             hsync_in,
	input             vsync_in,
	input             hblank_in,
	input             vblank_in,
	input             forced_scandoubler,
	input       [2:0] fx,           // 0 none, 1 HQ2x, 2..4 CRT scanlines 25/50/75%
	input       [1:0] aspect_mode,
	input       [1:0] scale_mode,
	input             rotation_active,
	input             video_rotated,
	input      [11:0] rotated_width,
	input      [11:0] rotated_height,
	input      [11:0] hdmi_width,
	input      [11:0] hdmi_height,
	output            ce_pixel,
	output            vga_hs,
	output            vga_vs,
	output      [1:0] vga_sl,
	output            vga_de,
	output      [7:0] vga_r,
	output      [7:0] vga_g,
	output      [7:0] vga_b,
	output     [12:0] video_arx,
	output     [12:0] video_ary,
	output     [23:0] rotate_rgb,
	output            rotate_hs,
	output            rotate_vs,
	output            rotate_de
);

// Preserve Leland's established MiSTer aspect codes: Original=4:3,
// Full Screen=0:0, ARC1=1:0, ARC2=2:0.
wire [11:0] aspect_x = (aspect_mode == 2'd0) ? 12'd4 : {10'd0, (aspect_mode - 2'd1)};
wire [11:0] aspect_y = (aspect_mode == 2'd0) ? 12'd3 : 12'd0;

// CONF_STR offers only Normal, V-Integer and HV-Integer. Map the donor's
// encodings (0, 1 and 4); illegal status code 3 falls back to Normal.
wire full_screen = (aspect_x == 12'd0) && (aspect_y == 12'd0);
wire [2:0] scale = full_screen ? 3'd0 :
				   (scale_mode == 2'd1) ? 3'd1 :
				   (scale_mode == 2'd2) ? 3'd4 : 3'd0;

wire [7:0] mix_r, mix_g, mix_b;
wire mix_hs, mix_vs, mix_de;
wire [21:0] unused_gamma_bus;
wire [12:0] normal_arx, normal_ary;
wire [12:0] rotated_arx, rotated_ary;
wire [11:0] rotated_aspect_x = (video_rotated && aspect_mode == 2'd0) ? aspect_y : aspect_x;
wire [11:0] rotated_aspect_y = (video_rotated && aspect_mode == 2'd0) ? aspect_x : aspect_y;

video_mixer #(
	.LINE_LENGTH(768),
	.HALF_DEPTH(0),
	.GAMMA(0)
) presentation_mixer (
	.CLK_VIDEO(clk_video),
	.CE_PIXEL(ce_pixel),
	.ce_pix(ce_pix_in),
	.scandoubler(forced_scandoubler || (fx != 3'd0)),
	.hq2x(fx == 3'd1),
	.gamma_bus(unused_gamma_bus),
	.R(rgb_in[23:16]),
	.G(rgb_in[15:8]),
	.B(rgb_in[7:0]),
	.HSync(hsync_in),
	.VSync(vsync_in),
	.HBlank(hblank_in),
	.VBlank(vblank_in),
	.HDMI_FREEZE(1'b0),
	.freeze_sync(),
	.VGA_R(mix_r),
	.VGA_G(mix_g),
	.VGA_B(mix_b),
	.VGA_VS(mix_vs),
	.VGA_HS(mix_hs),
	.VGA_DE(mix_de)
);

video_freak presentation_scaler (
	.CLK_VIDEO(clk_video),
	.CE_PIXEL(ce_pixel),
	.VGA_VS(mix_vs),
	.HDMI_WIDTH(hdmi_width),
	.HDMI_HEIGHT(hdmi_height),
	.VGA_DE(vga_de),
	.VIDEO_ARX(normal_arx),
	.VIDEO_ARY(normal_ary),
	.VGA_DE_IN(mix_de),
	.ARX(aspect_x),
	.ARY(aspect_y),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale)
);

// The framework framebuffer reports post-rotation dimensions. Feed those
// dimensions to the framework's integer-scaling arithmetic while it is active;
// the regular video_freak continues to measure the native/CRT raster otherwise.
video_scale_int rotated_scaler (
	.CLK_VIDEO(clk_video),
	.HDMI_WIDTH(hdmi_width),
	.HDMI_HEIGHT(hdmi_height),
	.SCALE(scale),
	.hsize(rotated_width),
	.vsize(rotated_height),
	.arx_i(rotated_aspect_x),
	.ary_i(rotated_aspect_y),
	.arx_o(rotated_arx),
	.ary_o(rotated_ary)
);

assign {vga_r, vga_g, vga_b} = {mix_r, mix_g, mix_b};
assign {vga_hs, vga_vs} = {mix_hs, mix_vs};
wire [2:0] scanline_code = (fx != 3'd0) ? fx - 3'd1 : 3'd0;
assign vga_sl = scanline_code[1:0];
assign {video_arx, video_ary} = rotation_active ? {rotated_arx, rotated_ary} : {normal_arx, normal_ary};
assign rotate_rgb = {mix_r, mix_g, mix_b};
assign {rotate_hs, rotate_vs, rotate_de} = {mix_hs, mix_vs, mix_de};

endmodule
