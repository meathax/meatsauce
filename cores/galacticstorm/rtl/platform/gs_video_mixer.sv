// SPDX-License-Identifier: GPL-3.0-or-later
// Template gamma/freezer/native frontend; explicit-CE Jotego doubled output.
// Source/patched profile: docs/video-mixer-provenance.md.
//
//
// Copyright (c) 2017,2021 Alexey Melnikov
//
// This program is GPL Licensed. See COPYING for the full license.
//
//
////////////////////////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

//
// LINE_LENGTH: Length of display line in pixels when HBlank = 0;
// HALF_DEPTH:  If =1 then color dept is 4 bits per component
//
// altera message_off 10720 
// altera message_off 12161

module gs_video_mixer
#(
	parameter LINE_LENGTH  = 768,
	parameter HALF_DEPTH   = 0,
	parameter GAMMA        = 0,
	parameter SCAN_BUFFER_LENGTH = 1024
)
(
	input            CLK_VIDEO, // should be multiple by (ce_pix*4)
	output wire      CE_PIXEL,  // output pixel clock enable

	input            reset,
	input            ce_pix2,
	input            ce_pix,    // input pixel clock or clock_enable

	input            scandoubler,
	input            hq2x, 	    // high quality 2x scaling

	inout     [21:0] gamma_bus,

	// color
	input [DWIDTH:0] R,
	input [DWIDTH:0] G,
	input [DWIDTH:0] B,

	// Positive pulses.
	input            HSync,
	input            VSync,
	input            HBlank,
	input            VBlank,

	// Freeze engine
	// HDMI: displays last frame 
	// VGA:  black screen with HSync and VSync
	input            HDMI_FREEZE,
	output           freeze_sync,

	// video output signals
	output wire [7:0] VGA_R,
	output wire [7:0] VGA_G,
	output wire [7:0] VGA_B,
	output wire       VGA_VS,
	output wire       VGA_HS,
	output wire       VGA_DE
);

localparam DWIDTH = HALF_DEPTH ? 3 : 7;
localparam DWIDTH_SD = GAMMA ? 7 : DWIDTH;
localparam HALF_DEPTH_SD = GAMMA ? 0 : HALF_DEPTH;

wire frz_hs, frz_vs;
wire frz_hbl, frz_vbl;
video_freezer freezer
(
	.clk(CLK_VIDEO),
	.freeze(HDMI_FREEZE),
	.hs_in(HSync),
	.vs_in(VSync),
	.hbl_in(HBlank),
	.vbl_in(VBlank),
	.sync(freeze_sync),
	.hs_out(frz_hs),
	.vs_out(frz_vs),
	.hbl_out(frz_hbl),
	.vbl_out(frz_vbl)
);

reg frz;
always @(posedge CLK_VIDEO) begin
	reg frz1;
	
	frz1 <= HDMI_FREEZE;
	frz  <= frz1;
end

wire [DWIDTH_SD:0] R_in,G_in,B_in;
generate
	if(GAMMA && HALF_DEPTH) begin
		assign R_in = frz ? 8'd0 : {R,R};
		assign G_in = frz ? 8'd0 : {G,G};
		assign B_in = frz ? 8'd0 : {B,B};
	end else begin
		assign R_in = frz ? 1'd0 : R;
		assign G_in = frz ? 1'd0 : G;
		assign B_in = frz ? 1'd0 : B;
	end
endgenerate

wire hs_g, vs_g;
wire hb_g, vb_g;
wire [DWIDTH_SD:0] R_gamma, G_gamma, B_gamma;

generate
	if(GAMMA) begin
		assign gamma_bus[21] = 1;
		gamma_corr gamma(
			.clk_sys(gamma_bus[20]),
			.clk_vid(CLK_VIDEO),
			.ce_pix(ce_pix),

			.gamma_en(gamma_bus[19]),
			.gamma_wr(gamma_bus[18]),
			.gamma_wr_addr(gamma_bus[17:8]),
			.gamma_value(gamma_bus[7:0]),

			.HSync(frz_hs),
			.VSync(frz_vs),
			.HBlank(frz_hbl),
			.VBlank(frz_vbl),
			.RGB_in({R_in,G_in,B_in}),

			.HSync_out(hs_g),
			.VSync_out(vs_g),
			.HBlank_out(hb_g),
			.VBlank_out(vb_g),
			.RGB_out({R_gamma,G_gamma,B_gamma})
		);
	end else begin
		assign gamma_bus[21] = 0;
		assign {R_gamma,G_gamma,B_gamma} = {R_in,G_in,B_in};
		assign {hs_g, vs_g, hb_g, vb_g} = {frz_hs, frz_vs, frz_hbl, frz_vbl};
	end
endgenerate

wire [DWIDTH_SD:0] R_sd;
wire [DWIDTH_SD:0] G_sd;
wire [DWIDTH_SD:0] B_sd;
wire hs_sd, vs_sd, hb_sd, vb_sd;

// Gamma/freezer processing stays at the native 24/125 enable rate.
// The line-buffer output and its CE share the donor's registered read latency.
reg ce_pix_sd;
always @(posedge CLK_VIDEO) begin
    ce_pix_sd<=ce_pix2;
    // Keep the forwarded /4 pixel cadence alive through game reset.
end
jtframe_scan2x #(.COLORW(DWIDTH_SD+1),.HLEN(SCAN_BUFFER_LENGTH),.GS_EXACT(1)) sd (
    .rst(reset),.clk(CLK_VIDEO),.pxl_cen(ce_pix),.pxl2_cen(ce_pix2),
    .enb(1'b0),.sl_mode(2'd0),.blend_en(1'b0),
    .rotation(2'd0),.hfilter(1'b0),.vfilter(1'b0),
    .x1_pxl({R_gamma,G_gamma,B_gamma}),.x1_hs(hs_g),.x1_vs(vs_g),.x1_hb(hb_g),.x1_vb(vb_g),
    .x2_pxl({R_sd,G_sd,B_sd}),.x2_hs(hs_sd),.x2_vs(vs_sd),.x2_HB(hb_sd),.x2_VB(vb_sd),.x2_de(),
    .init(1'b0),.sd_data(),.sd_addr(),.sd_dqm(),.sd_ba(),
    .sd_cs(),.sd_we(),.sd_ras(),.sd_cas(),.sd_cke());
reg native_ce;
reg [7:0] native_r,native_g,native_b;
reg native_hs,native_vs,native_de;
wire [7:0] doubled_r,doubled_g,doubled_b;
generate if(!GAMMA && HALF_DEPTH) begin
    assign doubled_r={R_sd,R_sd};assign doubled_g={G_sd,G_sd};assign doubled_b={B_sd,B_sd};
end else begin
    assign doubled_r=R_sd;assign doubled_g=G_sd;assign doubled_b=B_sd;
end endgenerate
assign CE_PIXEL=scandoubler ? ce_pix_sd : native_ce;
assign VGA_R=scandoubler ? doubled_r : native_r;
assign VGA_G=scandoubler ? doubled_g : native_g;
assign VGA_B=scandoubler ? doubled_b : native_b;
assign VGA_HS=scandoubler ? hs_sd : native_hs;
assign VGA_VS=scandoubler ? vs_sd : native_vs;
assign VGA_DE=scandoubler ? !(hb_sd || vb_sd) : native_de;

wire [DWIDTH_SD:0] rt = R_gamma;
wire [DWIDTH_SD:0] gt = G_gamma;
wire [DWIDTH_SD:0] bt = B_gamma;

always @(posedge CLK_VIDEO) begin
	reg [7:0] r,g,b;
	reg hde,vde,hs,vs, old_vs;
	reg old_hde;
	reg old_ce;
	reg ce_osc, fs_osc;
	
	old_ce <= ce_pix;
	ce_osc <= ce_osc | (old_ce ^ ce_pix);

	old_vs <= vs;
	if(~old_vs & vs) begin
		fs_osc <= ce_osc;
		ce_osc <= 0;
	end

	native_ce <= fs_osc ? (~old_ce & ce_pix) : ce_pix;

	if(!GAMMA && HALF_DEPTH) begin
		r <= {rt,rt};
		g <= {gt,gt};
		b <= {bt,bt};
	end
	else begin
		r <= rt;
		g <= gt;
		b <= bt;
	end

	hde <= ~hb_g;
	vde <= ~vb_g;
	vs  <= vs_g;
	hs  <= hs_g;

	if(native_ce) begin
		native_r <= r;
		native_g <= g;
		native_b <= b;

		native_vs <= vs;
		native_hs <= hs;

		old_hde <= hde;
		if(old_hde ^ hde) native_de <= vde & hde;
	end
end

endmodule
