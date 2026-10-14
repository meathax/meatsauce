`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Board video composition: ICY draw/display buffers, programmable polygon
// palette, and the alphanumeric overlay.
module irobot_video_pipeline (
	input logic draw_clk,input logic video_clk,input logic reset,input logic ce_pixel,
	input logic[8:0]hcount,input logic[7:0]vcount,
	input logic draw_we,input logic[15:0]draw_addr,input logic[6:0]draw_data,
	input logic swap,input logic clear_start,
	input logic palette_we,input logic palette_rw,input logic[15:0]palette_addr,input logic[7:0]palette_data,
	input logic alpha_cpu_we,input logic[9:0]alpha_cpu_addr,input logic[7:0]alpha_cpu_data,
	output logic[7:0]alpha_cpu_dout,
	input logic alpha_char_we,input logic[10:0]alpha_char_addr,input logic[7:0]alpha_char_data,
	input logic alpha_prom_we,input logic[4:0]alpha_prom_addr,input logic[7:0]alpha_prom_data,
	input logic alphamap,input logic cocktail_flip,
	output logic[7:0]red,green,blue,
	output logic clear_busy,output logic clear_done,output logic draw_ready,
	output logic draw_bank,output logic display_bank,output logic detail_pixel
);
	logic[6:0]pixel;
	logic[7:0]poly_r,poly_g,poly_b,alpha_r,alpha_g,alpha_b;logic alpha_opaque;
	logic[15:0]display_addr /* verilator public_flat_rd */;
	logic cocktail_meta,cocktail_sync;
	always_ff @(posedge video_clk) begin
		if(reset) begin cocktail_meta<=0;cocktail_sync<=0;end
		else begin cocktail_meta<=cocktail_flip;cocktail_sync<=cocktail_meta;end
	end
	assign display_addr={vcount,hcount[7:0]};
	assign detail_pixel=pixel[6];
	irobot_framebuffers fb(.draw_clk(draw_clk),.display_clk(video_clk),.reset(reset),
		.draw_we(draw_we),.draw_addr(draw_addr),.draw_data(draw_data),.display_addr(display_addr),
		.swap(swap),.clear_start(clear_start),.display_data(pixel),.draw_bank(draw_bank),.display_bank(display_bank),
		.clear_busy(clear_busy),.clear_done(clear_done),.draw_ready(draw_ready));
	irobot_palette palette(draw_clk,video_clk,reset,palette_we,palette_rw,palette_addr,palette_data,pixel[5:0],poly_r,poly_g,poly_b);
	irobot_alpha alpha(draw_clk,draw_clk,video_clk,alpha_cpu_we,alpha_cpu_addr,alpha_cpu_data,alpha_cpu_dout,
		alpha_char_we,alpha_char_addr,alpha_char_data,alpha_prom_we,alpha_prom_addr,alpha_prom_data,
		alphamap,cocktail_sync,hcount[7:0],vcount,alpha_opaque,alpha_r,alpha_g,alpha_b);
	always_ff @(posedge video_clk) begin
		if(reset)begin red<=0;green<=0;blue<=0;end
		else if(ce_pixel)begin
			if(hcount[8]||vcount>=8'd232)begin red<=0;green<=0;blue<=0;end
			else if(alpha_opaque)begin red<=alpha_r;green<=alpha_g;blue<=alpha_b;end
			else begin red<=poly_r;green<=poly_g;blue<=poly_b;end
		end
	end
endmodule
