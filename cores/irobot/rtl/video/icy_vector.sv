`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// One-pixel-per-clock vector primitive with native framebuffer clip.
//
// The stepper reproduces the board's line generator exactly as the MAME
// behavioural model describes it (irobot_v.cpp draw_line, lines 206-245):
// the major axis advances on every iteration and the minor axis advances
// when the error accumulator, seeded with half the major-axis length,
// goes negative.  The symmetric "both tests" Bresenham that this module
// used before seeds the error with dx-dy instead, which puts the minor
// axis in a different phase and moves about seven pixels on a third of
// all lines.
module icy_vector (
	input logic clk,input logic reset,input logic start,
	input logic signed[9:0]x0,y0,x1,y1,input logic[5:0]color,
	output logic busy,output logic done,output logic fb_we,output logic[15:0]fb_addr,output logic[6:0]fb_data
);
	logic signed[12:0]cx,cy,tx,ty,dx,dy,sx,sy,err;
	logic major_x;
	logic signed[12:0]ex0,ey0,ex1,ey1,adx,ady,step_err;
	always_comb begin
		ex0={{3{x0[9]}},x0};ey0={{3{y0[9]}},y0};ex1={{3{x1[9]}},x1};ey1={{3{y1[9]}},y1};
		adx=ex1>=ex0?ex1-ex0:ex0-ex1;
		ady=ey1>=ey0?ey1-ey0:ey0-ey1;
		// The error step subtracts the minor-axis length on the major axis.
		step_err=major_x?(err-dy):(err-dx);
	end
	always_ff @(posedge clk) begin
		done<=0;fb_we<=0;
		if(reset)busy<=0;
		else if(start&&!busy)begin
			cx<=ex0;cy<=ey0;tx<=ex1;ty<=ey1;
			dx<=adx;dy<=ady;
			sx<=ex0<=ex1?13'sd1:-13'sd1;sy<=ey0<=ey1?13'sd1:-13'sd1;
			major_x<=adx>=ady;
			err<=(adx>=ady?adx:ady)>>>1;
			busy<=1;
		end else if(busy)begin
			if(cx>=0&&cx<256&&cy>=0&&cy<232)begin fb_we<=1;fb_addr<={cy[7:0],cx[7:0]};fb_data<={1'b0,color};end
			if(major_x?(cx==tx):(cy==ty))begin busy<=0;done<=1;end
			else if(major_x)begin
				cx<=cx+sx;
				if(step_err<0)begin cy<=cy+sy;err<=step_err+dx;end else err<=step_err;
			end else begin
				cy<=cy+sy;
				if(step_err<0)begin cx<=cx+sx;err<=step_err+dy;end else err<=step_err;
			end
		end
	end
endmodule
