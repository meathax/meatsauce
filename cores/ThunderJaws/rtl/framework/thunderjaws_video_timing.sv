// SPDX-License-Identifier: GPL-3.0-or-later
// VAD sync decode adapted from pinned Batman batman_vad_sync.sv
// Copyright (C) 2026 the Batman MiSTer core authors.
// Native ThunderJaws boot writes0795/0aef/5eef/beb1 (retained MAME write sweep).
// HS is high for14MHz counts751..813, VS for lines242..244. Half-pixel
// edges use the same clk_sys, halfway between fixed integer pixel enables.
module thunderjaws_video_timing #(parameter integer PIXEL_DIVIDER=6) (
 input wire clk_sys,init_reset,ce_in,de_in,
 input wire [8:0] h_in,v_in,
 input wire [7:0] r_in,g_in,b_in,
 output reg ce_out,de_out,hblank,vblank,hsync,vsync,
 output reg [7:0] r_out,g_out,b_out
 ,output reg [8:0] h_out,v_out
);
 localparam integer CW=$clog2(PIXEL_DIVIDER);
 reg [CW-1:0] since_pixel;
 reg [8:0] last_h;
 always @(posedge clk_sys)begin
  ce_out<=ce_in;
  if(init_reset)begin
   ce_out<=0;de_out<=0;hblank<=1;vblank<=1;hsync<=0;vsync<=0;
   r_out<=0;g_out<=0;b_out<=0;since_pixel<=0;last_h<=0;h_out<=0;v_out<=240;
  end else if(ce_in)begin
   since_pixel<=0;last_h<=h_in;h_out<=h_in;v_out<=v_in;
   de_out<=de_in;hblank<=h_in>=336;vblank<=v_in>=240;
   r_out<=de_in ? r_in : 0;g_out<=de_in ? g_in : 0;b_out<=de_in ? b_in : 0;
   if(h_in==407)hsync<=0;
   if(h_in==0)begin
    if(v_in==242)vsync<=1;
    else if(v_in==245)vsync<=0;
   end
  end else begin
   if(since_pixel<PIXEL_DIVIDER-1)since_pixel<=since_pixel+1'b1;
   if(since_pixel==PIXEL_DIVIDER/2-1 && last_h==375)hsync<=1;
  end
 end
endmodule
