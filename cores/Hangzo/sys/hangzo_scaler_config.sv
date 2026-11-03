// SPDX-License-Identifier: GPL-3.0-or-later
// Atomic scaler configuration for independent HDMI and Avalon consumers.
module hangzo_scaler_config(
    input wire src_clk,src_valid,video_clk,avl_clk,
    input wire [11:0] src_htotal,
    input wire [11:0] src_hsstart,
    input wire [11:0] src_hsend,
    input wire [11:0] src_hdisp,
    input wire [11:0] src_hmin,
    input wire [11:0] src_hmax,
    input wire [11:0] src_vtotal,
    input wire [11:0] src_vsstart,
    input wire [11:0] src_vsend,
    input wire [11:0] src_vdisp,
    input wire [11:0] src_vmin,
    input wire [11:0] src_vmax,
    input wire [11:0] src_vrrmax,
    input wire [4:0] src_mode,
    input wire src_o_ce,
    input wire src_vrr,
    input wire src_swblack,
    input wire src_bob_deint,
    input wire src_freeze,
    input wire src_o_fb_ena,
    input wire [11:0] src_o_fb_hsize,
    input wire [11:0] src_o_fb_vsize,
    input wire [5:0] src_o_fb_format,
    input wire [31:0] src_o_fb_base,
    input wire [13:0] src_o_fb_stride,
    output wire [11:0] dst_htotal,
    output wire [11:0] dst_hsstart,
    output wire [11:0] dst_hsend,
    output wire [11:0] dst_hdisp,
    output wire [11:0] dst_hmin,
    output wire [11:0] dst_hmax,
    output wire [11:0] dst_vtotal,
    output wire [11:0] dst_vsstart,
    output wire [11:0] dst_vsend,
    output wire [11:0] dst_vdisp,
    output wire [11:0] dst_vmin,
    output wire [11:0] dst_vmax,
    output wire [11:0] dst_vrrmax,
    output wire [4:0] dst_mode,
    output wire dst_o_ce,
    output wire dst_vrr,
    output wire dst_swblack,
    output wire dst_bob_deint,
    output wire dst_freeze,
    output wire dst_o_fb_ena,
    output wire [11:0] dst_o_fb_hsize,
    output wire [11:0] dst_o_fb_vsize,
    output wire [5:0] dst_o_fb_format,
    output wire [31:0] dst_o_fb_base,
    output wire [13:0] dst_o_fb_stride,
    output wire [242:0] video_snapshot,
    output wire avl_fb_ena,
    output wire [31:0] avl_fb_base
);
    wire [242:0] video_word;
    wire [32:0] avl_word;
    assign video_snapshot=video_word;
    hangzo_cdc_latest #(.WIDTH(243)) video_cdc(
        .src_clk(src_clk), .src_valid(src_valid), .src_data({src_htotal,src_hsstart,src_hsend,src_hdisp,src_hmin,src_hmax,src_vtotal,src_vsstart,src_vsend,src_vdisp,src_vmin,src_vmax,src_vrrmax,src_mode,src_o_ce,src_vrr,src_swblack,src_bob_deint,src_freeze,src_o_fb_ena,src_o_fb_hsize,src_o_fb_vsize,src_o_fb_format,src_o_fb_base,src_o_fb_stride}),
        .src_ready(), .dst_clk(video_clk), .dst_ready(1'b1), .dst_data(video_word), .dst_strobe()
    );
    assign {dst_htotal,dst_hsstart,dst_hsend,dst_hdisp,dst_hmin,dst_hmax,dst_vtotal,dst_vsstart,dst_vsend,dst_vdisp,dst_vmin,dst_vmax,dst_vrrmax,dst_mode,dst_o_ce,dst_vrr,dst_swblack,dst_bob_deint,dst_freeze,dst_o_fb_ena,dst_o_fb_hsize,dst_o_fb_vsize,dst_o_fb_format,dst_o_fb_base,dst_o_fb_stride}=video_word;
    hangzo_cdc_latest #(.WIDTH(33)) avalon_cdc(
        .src_clk(src_clk), .src_valid(src_valid), .src_data({src_o_fb_ena,src_o_fb_base}),
        .src_ready(), .dst_clk(avl_clk), .dst_ready(1'b1), .dst_data(avl_word), .dst_strobe()
    );
    assign {avl_fb_ena,avl_fb_base}=avl_word;
endmodule
