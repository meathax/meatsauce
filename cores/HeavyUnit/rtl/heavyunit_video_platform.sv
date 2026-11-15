// SPDX-License-Identifier: GPL-3.0-or-later
// Standard MiSTer presentation wrapper. Raw renderer metadata is already aligned.
// REFERENCE_ONLY framebuffer markers and bypass do not qualify native CRT timing.
module heavyunit_video_platform #(
 parameter integer NATIVE_PIXEL_DIV=0,NATIVE_HTOTAL=0,NATIVE_VTOTAL=0,NATIVE_HACTIVE_START=0,NATIVE_HS_REFERENCE=0,
 parameter integer CRT_HSIZE_MIN=0,CRT_HSIZE_MAX=0,CRT_HPOS_MIN=0,CRT_HPOS_MAX=0,CRT_VPOS_MIN=0,CRT_VPOS_MAX=0
)(

 input logic clk,reset,
 input logic [23:0] rgb,
 input logic ce_pixel,hs,vs,hb,vb,de,
 input logic [7:0] pixel_x,
 input logic reference_profile,native_sync_qualified,
 input logic native_frame_boundary,crt_enable,
 input logic signed [4:0] crt_hsize,crt_vposition,
 input logic signed [6:0] crt_hposition,
 output logic crt_active,crt_available,crt_range_clamped,
 input logic direct_video,forced_scandoubler,
 input logic [2:0] effect,
 inout wire [21:0] gamma_bus,
 input logic [11:0] hdmi_width,hdmi_height,aspect_x,aspect_y,
 input logic [1:0] scale_mode, // 0 Normal,1 V-Integer,2 HV-Integer
 input logic [1:0] orientation, // 0 Normal,1 CW90,2 CCW90,3 renderer180
 input logic rotation_enable,rotation_pause,
 input logic fb_vblank,fb_low_latency,ddram_busy,writes_drained,
 output logic clk_video,output_ce,vga_hs,vga_vs,vga_de,
 output logic [7:0] vga_r,vga_g,vga_b,
 output logic [1:0] vga_sl,
 output logic [12:0] video_arx,video_ary,
 output logic output_sync_qualified,
 output logic [23:0] raw_rgb,
 output logic raw_ce,raw_hs,raw_vs,raw_hb,raw_vb,raw_de,
 output logic producer_quiescent,metadata_error,fb_enable,video_rotated,
 output logic [4:0] fb_format,
 output logic [11:0] fb_width,fb_height,
 output logic [31:0] fb_base,
 output logic [13:0] fb_stride,
 output logic [7:0] write_burstcount,write_byteenable,
 output logic [28:0] write_address,
 output logic [63:0] write_data,
 output logic write_valid
);
 wire rotate90=orientation==1 || orientation==2;
 wire [2:0] scale=scale_mode==1 ? 3'd1 : scale_mode==2 ? 3'd4 : 3'd0;
 wire [11:0] arx=rotate90 ? aspect_y : aspect_x;
 wire [11:0] ary=rotate90 ? aspect_x : aspect_y;
 wire crt_ce,crt_hs,crt_vs,crt_hb,crt_vb;
 wire [23:0] crt_rgb;
 // CRT Adjust (darkmist glue): option codes match the OSD lists exactly.
 // H-Size 0,+1,+2,-2,-1 -> codes 0..4; H-Position/V-Shift 5-bit two's complement.
 wire [2:0] crt_hsize_option=crt_hsize==5'sd1 ? 3'd1 : crt_hsize==5'sd2 ? 3'd2 :
                              crt_hsize==-5'sd2 ? 3'd3 : crt_hsize==-5'sd1 ? 3'd4 : 3'd0;
 wire crt_native=!reference_profile && native_sync_qualified;
 wire crt_glue_ce,crt_glue_active,crt_glue_hs,crt_glue_vs,crt_glue_hb,crt_glue_vb;
 wire [7:0] crt_glue_r,crt_glue_g,crt_glue_b;
 heavyunit_crt #(.HTOTAL(NATIVE_HTOTAL),.VTOTAL(NATIVE_VTOTAL)) crt (
  .clk,.reset(reset || !crt_native),.ce_in(ce_pixel),.enable(crt_enable && crt_native),
  .hsize_option(crt_hsize_option),.hpos_option(crt_hposition[4:0]),.vpos_option(crt_vposition[4:0]),
  .r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),.hs_in(hs),.vs_in(vs),.hb_in(hb),.vb_in(vb),
  .ce_out(crt_glue_ce),.active(crt_glue_active),.r_out(crt_glue_r),.g_out(crt_glue_g),.b_out(crt_glue_b),
  .hs_out(crt_glue_hs),.vs_out(crt_glue_vs),.hb_out(crt_glue_hb),.vb_out(crt_glue_vb),.read_period()
 );
 assign crt_active=crt_glue_active;
 assign crt_available=crt_native;
 assign crt_range_clamped=1'b0;
 assign crt_ce=crt_glue_active ? crt_glue_ce : ce_pixel;
 assign crt_rgb=crt_glue_active ? {crt_glue_r,crt_glue_g,crt_glue_b} : rgb;
 assign {crt_hs,crt_vs,crt_hb,crt_vb}=crt_glue_active ? {crt_glue_hs,crt_glue_vs,crt_glue_hb,crt_glue_vb} : {hs,vs,hb,vb};
 wire std_ce,std_hs,std_vs,std_de;
 wire [7:0] std_r,std_g,std_b;
 wire [1:0] std_sl;
 heavyunit_arcade_video #(.WIDTH(256),.DW(24),.GAMMA(1)) standard (
  .clk_video(clk),.ce_pix(crt_ce),.RGB_in(crt_rgb),
  .HBlank(crt_hb),.VBlank(crt_vb),.HSync(crt_hs),.VSync(crt_vs),
  .CLK_VIDEO(),.CE_PIXEL(std_ce),.VGA_R(std_r),.VGA_G(std_g),.VGA_B(std_b),
  .VGA_HS(std_hs),.VGA_VS(std_vs),.VGA_DE(std_de),.VGA_SL(std_sl),
  .fx(direct_video ? 3'd0 : effect),
  .forced_scandoubler(forced_scandoubler && !direct_video),.gamma_bus
 );
 assign clk_video=clk;
 assign output_sync_qualified=!reference_profile && native_sync_qualified;
 assign raw_rgb=rgb;
 assign {raw_ce,raw_hs,raw_vs,raw_hb,raw_vb,raw_de}={ce_pixel,hs,vs,hb,vb,de};
 // Compatibility HB is permanently zero, so arcade_video cannot latch its
 // frame blank through an HBlank edge. Bypass only that explicitly marked mode.
 assign output_ce=reference_profile ? ce_pixel : std_ce;
 assign {vga_r,vga_g,vga_b}=reference_profile ? rgb : {std_r,std_g,std_b};
 assign {vga_hs,vga_vs}=reference_profile ? {hs,vs} : {std_hs,std_vs};
 assign vga_sl=reference_profile ? 2'd0 : std_sl;
 logic line_marker;
 always_ff @(posedge clk) begin
  if(reset) line_marker<=0;
  else line_marker<=ce_pixel && de && pixel_x==255;
 end
 wire measure_ce=reference_profile ? ce_pixel || line_marker : std_ce;
 wire measure_de=reference_profile ? ce_pixel && de && !line_marker : std_de;
 wire measure_vs=reference_profile ? vb : std_vs;
 wire crop_de;
 wire [12:0] normal_arx,normal_ary,rotated_arx,rotated_ary;
 video_freak presentation (
  .CLK_VIDEO(clk),.CE_PIXEL(measure_ce),.VGA_VS(measure_vs),
  .HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),.VGA_DE(crop_de),
  .VIDEO_ARX(normal_arx),.VIDEO_ARY(normal_ary),.VGA_DE_IN(measure_de),
  .ARX(arx),.ARY(ary),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(scale)
 );
 // video_freak measures unrotated input. The real standard integer scaler uses
 // the donor's rotated framebuffer dimensions for the 90-degree viewport.
 // Reference profile: the image is always the fixed 256x224 (224x256 rotated)
 // logical frame. Never re-derive VIDEO_ARX/ARY (part of sys fb_crc) from a
 // per-frame raster measurement: a renderer-missed line would change them and
 // MiSTer Main would re-apply the video mode, retuning the HDMI PLL.
 wire [11:0] scale_w=rotate90 ? 12'd224 : 12'd256;
 wire [11:0] scale_h=rotate90 ? 12'd256 : 12'd224;
 video_scale_int rotated_scale (
  .CLK_VIDEO(clk),.HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),.SCALE(scale),
  .hsize(scale_w),.vsize(scale_h),.arx_i(arx),.ary_i(ary),
  .arx_o(rotated_arx),.ary_o(rotated_ary)
 );
 assign video_arx=rotated_arx;
 assign video_ary=rotated_ary;
 assign vga_de=reference_profile ? de : crop_de;
 logic reference_profile_q;
 always_ff @(posedge clk)begin if(reset)reference_profile_q<=reference_profile;else reference_profile_q<=reference_profile;end
 wire profile_changed=reference_profile_q!=reference_profile;
 wire producer_enabled,select_reference_metadata;
 heavyunit_video_admission admission(.reference_profile,.native_sync_qualified,.rotation_enable,.rotation_pause,
  .producer_enabled,.select_reference_metadata);
 // The analog/direct renderer applies 180 once. Its orientation never enables
 // another framebuffer flip. Normal/180 use offset-cancelled donor flip for linear FB.
 heavyunit_reference_framebuffer framebuffer (
  .clk,.reset(reset || profile_changed || (!reference_profile && !native_sync_qualified)),.enable(producer_enabled),.rotation(orientation==2 ? 2'd1 : rotate90 ? 2'd0 : 2'd2),
  .linearize_flip(!rotate90),.orientation_generation(orientation),.writes_drained,
  .pixel_ce(ce_pixel),.pixel_de(!hb && !vb),.pixel_vblank(vb),.pixel_x,.pixel_rgb(rgb),
  .fb_vblank,.fb_low_latency,.ddram_busy,.producer_quiescent,.metadata_error,
  .fb_enable,.video_rotated,.fb_format,.fb_width,.fb_height,.fb_base,.fb_stride,
  .write_burstcount,.write_byteenable,.write_address,.write_data,.write_valid,
  .reference_ce(),.reference_de(),.reference_vs()
 );
endmodule
