// SPDX-License-Identifier: GPL-3.0-or-later
// Actual core presentation path, shared verbatim by emu and the display bench.
module thunderjaws_video_output(
 input wire clk_sys,init_reset,raw_ce,raw_de,raw_hs,raw_vs,
 input wire [8:0] raw_h,raw_v,
 input wire [23:0] raw_rgb,
 input wire crt_enable,
 input wire signed [4:0] crt_size,crt_vertical,
 input wire signed [6:0] crt_horizontal,
 input wire direct_video,forced_scandoubler,
 input wire [2:0] effect,
 input wire [1:0] aspect_choice,scale_mode,
 input wire rotate90,rotate_ccw,
 input wire [11:0] hdmi_width,hdmi_height,
 inout wire [21:0] gamma_bus,
 output wire ce_pixel,vga_de,vga_hs,vga_vs,
 output wire [23:0] vga_rgb,
 output wire [1:0] vga_sl,
 output wire [12:0] video_arx,video_ary,
 input wire fb_vblank,ddram_busy,
 output wire fb_enable,
 output wire [4:0] fb_format,
 output wire [11:0] fb_width,fb_height,
 output wire [31:0] fb_base,
 output wire [13:0] fb_stride,
 output wire ddram_clk,ddram_we,ddram_rd,
 output wire [28:0] ddram_address,
 output wire [63:0] ddram_data,
 output wire [7:0] ddram_byteenable,ddram_burstcount,
 output wire rotation_overflow
);
 wire native_direct=direct_video && !forced_scandoubler;
 wire native_output=!forced_scandoubler && (direct_video || effect==0);
 wire crt_ce,crt_de,crt_hb,crt_vb,crt_hs,crt_vs;wire [23:0] crt_rgb;
 thunderjaws_crt geometry(.clk_sys(clk_sys),.init_reset(init_reset),.ce_in(raw_ce),.de_in(raw_de),.hs_in(raw_hs),.vs_in(raw_vs),
 .h_in(raw_h),.v_in(raw_v),.rgb_in(raw_rgb),.enable(crt_enable),.hsize(crt_size),.hposition(crt_horizontal),.vposition(crt_vertical),
 .ce_out(crt_ce),.de_out(crt_de),.hblank(crt_hb),.vblank(crt_vb),.hs_out(crt_hs),.vs_out(crt_vs),.rgb_out(crt_rgb));
 wire gamma_ce,gamma_de,gamma_hb,gamma_vb,gamma_hs,gamma_vs;wire [23:0] gamma_rgb;
 thunderjaws_gamma correction(.clk_sys(clk_sys),.init_reset(init_reset),.ce_in(crt_ce),.de_in(crt_de),.hb_in(crt_hb),.vb_in(crt_vb),
 .hs_in(crt_hs),.vs_in(crt_vs),.rgb_in(crt_rgb),.gamma_bus(gamma_bus),
 .ce_out(gamma_ce),.de_out(gamma_de),.hb_out(gamma_hb),.vb_out(gamma_vb),.hs_out(gamma_hs),.vs_out(gamma_vs),.rgb_out(gamma_rgb));
 wire [21:0] unused_gamma;assign unused_gamma[20:0]=0;
 wire mixer_ce,mixer_de,mixer_hs,mixer_vs;wire [23:0] mixer_rgb;wire [1:0] mixer_sl;
 arcade_video #(.WIDTH(456),.DW(24),.GAMMA(0)) video(.clk_video(clk_sys),.ce_pix(gamma_ce),.RGB_in(gamma_rgb),
 .HBlank(gamma_hb),.VBlank(gamma_vb),.HSync(gamma_hs),.VSync(gamma_vs),.CLK_VIDEO(),.CE_PIXEL(mixer_ce),
 .VGA_R(mixer_rgb[23:16]),.VGA_G(mixer_rgb[15:8]),.VGA_B(mixer_rgb[7:0]),.VGA_HS(mixer_hs),.VGA_VS(mixer_vs),.VGA_DE(mixer_de),.VGA_SL(mixer_sl),
 .fx(native_direct ? 3'd0 : effect),.forced_scandoubler(forced_scandoubler),.gamma_bus(unused_gamma));
 // Native VGA and Direct Video both retain the VAD half-pixel sync edges.
 assign ce_pixel=native_output ? gamma_ce : mixer_ce;
 assign vga_rgb=native_output ? gamma_rgb : mixer_rgb;
 assign vga_hs=native_output ? gamma_hs : mixer_hs;
 assign vga_vs=native_output ? gamma_vs : mixer_vs;
 assign vga_sl=native_output ? 2'd0 : mixer_sl;
 wire selected_de=native_output ? gamma_de : mixer_de;
 video_freak scaler(.CLK_VIDEO(clk_sys),.CE_PIXEL(ce_pixel),.VGA_VS(vga_vs),.HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),
 .VGA_DE(vga_de),.VIDEO_ARX(video_arx),.VIDEO_ARY(video_ary),.VGA_DE_IN(selected_de),
 .ARX(aspect_choice==0 ? (rotate90 ? 12'd3 : 12'd4) : {10'd0,aspect_choice}-12'd1),
 .ARY(aspect_choice==0 ? (rotate90 ? 12'd4 : 12'd3) : 12'd0),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),
 .SCALE(direct_video ? 3'd0 : scale_mode==2 ? 3'd4 : {1'b0,scale_mode}));
 thunderjaws_rotate rotation(.clk_sys(clk_sys),.init_reset(init_reset),.enable(rotate90),.rotate_ccw(rotate_ccw),
 .ce_pixel(mixer_ce),.de(mixer_de),.vs(mixer_vs),.rgb(mixer_rgb),.fb_vblank(fb_vblank),.ddram_busy(ddram_busy),
 .fb_enable(fb_enable),.fb_format(fb_format),.fb_width(fb_width),.fb_height(fb_height),.fb_base(fb_base),.fb_stride(fb_stride),
 .ddram_clk(ddram_clk),.ddram_we(ddram_we),.ddram_rd(ddram_rd),.ddram_address(ddram_address),.ddram_data(ddram_data),
 .ddram_byteenable(ddram_byteenable),.ddram_burstcount(ddram_burstcount),.overflow(rotation_overflow));
endmodule
