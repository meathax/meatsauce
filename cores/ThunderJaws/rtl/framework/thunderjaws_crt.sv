// SPDX-License-Identifier: GPL-3.0-or-later
// Target adaptation of rmonic79/Umberto Parisi's GPLv3 CRT Adjust content-shift
// ping-pong buffer (pinned in donors/framework). Fixed /6 output pixel grid:
// resize source addresses, never CE_PIXEL. Explicit target coordinates avoid
// transplanting the donor's different raster/read-clock centering tables.
module thunderjaws_crt(
 input wire clk_sys,init_reset,ce_in,de_in,hs_in,vs_in,
 input wire [8:0] h_in,v_in,
 input wire [23:0] rgb_in,
 input wire enable,
 input wire signed [4:0] hsize,vposition,
 input wire signed [6:0] hposition,
 output reg active,
 output reg ce_out,de_out,hblank,vblank,hs_out,vs_out,
 output reg [23:0] rgb_out
);
 reg signed [4:0] size_q,vertical_q;
 reg signed [6:0] horizontal_q;
 always @(posedge clk_sys)begin
  if(init_reset)begin active<=0;size_q<=0;vertical_q<=0;horizontal_q<=0;end
  else if(ce_in && h_in==0 && v_in==240)begin
   active<=enable;size_q<=hsize < -2 ? -5'sd2 : hsize > 2 ? 5'sd2 : hsize;
   horizontal_q<=hposition;vertical_q<=vposition;
  end
 end
 reg [23:0] memory[0:1023];
 reg bank,valid0,valid1;
 reg [8:0] tag0,tag1;
 reg [8:0] line_pixels;
 always @(posedge clk_sys)begin
  if(ce_in && de_in && h_in<336)memory[{bank,h_in}]<=rgb_in;
  if(init_reset)begin bank<=0;valid0<=0;valid1<=0;tag0<=240;tag1<=240;line_pixels<=0;end
  else if(ce_in && h_in==400)begin
   bank<=!bank;line_pixels<=0;
   if(bank)begin tag1<=v_in;valid1<=line_pixels==336;end else begin tag0<=v_in;valid0<=line_pixels==336;end
  end else if(ce_in && de_in && h_in<336)line_pixels<=line_pixels+1'b1;
 end
 // The write bank switches inside native blanking after the line is complete.
 // Source pixels are therefore never read from a bank still being produced.
 wire [8:0] phase=h_in>=400 ? h_in-9'd400 : h_in+9'd56;
 reg [8:0] width_pixels;
 always @*case(size_q)
  -2:width_pixels=252;-1:width_pixels=294;1:width_pixels=378;2:width_pixels=420;
  default:width_pixels=336;
 endcase
 wire signed [11:0] start_x=12'sd224-$signed({3'd0,width_pixels>>1})+$signed(horizontal_q);
 wire signed [11:0] local_x=$signed({3'd0,phase})-start_x;
 wire [14:0] numerator={local_x[11:0],3'd0};
 // Exact floor(n/d) for every unsigned15 n: for d=6/7/9/10,
 // K=ceil(2^19/d) and 32767*(K*d-2^19)<2^19. Keep the same
 // low12 quotient bits, including addresses outside the visible window.
 reg [16:0] reciprocal;
 always @*case(size_q)
  -2:reciprocal=17'd87382;-1:reciprocal=17'd74899;
   1:reciprocal=17'd58255;2:reciprocal=17'd52429;
  default:reciprocal=17'd65536;
 endcase
 wire [31:0] address_product=numerator*reciprocal;
 wire [11:0] source_x=address_product[30:19];
 wire window=local_x>=0 && local_x<$signed({3'd0,width_pixels}) && source_x<336;
 wire cutover=h_in==400;
 wire read_bank=cutover ? bank : !bank;
 wire source_valid=cutover ? line_pixels==336 : bank ? valid0 : valid1;
 wire [8:0] source_line=cutover ? v_in : bank ? tag0 : tag1;
 wire source_blank=!source_valid || source_line>=240;
 reg ce_d,pass_d,hblank_d,vblank_d,hs_d,vs_d;
 reg [23:0] read_data,bypass_data;
 // Keep the synchronous RAM read free of reset logic. Bank validity and
 // pass_d mask unwritten storage; the first CE fills read_data before use.
 always @(posedge clk_sys)if(ce_in)read_data<=memory[{read_bank,source_x[8:0]}];
 reg signed [10:0] shifted_line;
 always @*begin
  shifted_line=$signed({2'd0,v_in})-11'sd1-$signed(vertical_q);
  if(shifted_line<0)shifted_line=shifted_line+11'sd262;
  else if(shifted_line>=262)shifted_line=shifted_line-11'sd262;
 end
 wire adjusted_vs=shifted_line>=242 && shifted_line<245;
 always @(posedge clk_sys)begin
  ce_d<=ce_in;ce_out<=ce_d;
  // Full-rate sync pipeline preserves the native half-pixel HS edge/width.
  hs_d<=hs_in;hs_out<=hs_d;
  vs_d<=active ? adjusted_vs : vs_in;vs_out<=vs_d;
  if(ce_in)begin
   bypass_data<=rgb_in;
   pass_d<=active ? window && !source_blank : de_in;
   hblank_d<=active ? !window : h_in>=336;
   vblank_d<=active ? source_blank : v_in>=240;
  end
  if(ce_d)begin
   rgb_out<=pass_d ? (active ? read_data : bypass_data) : 24'd0;
   de_out<=pass_d;hblank<=hblank_d;vblank<=vblank_d;
  end
  if(init_reset)begin
   ce_d<=0;ce_out<=0;pass_d<=0;hblank_d<=1;vblank_d<=1;hs_d<=0;hs_out<=0;vs_d<=0;vs_out<=0;
   bypass_data<=0;rgb_out<=0;de_out<=0;hblank<=1;vblank<=1;
  end
 end
endmodule
