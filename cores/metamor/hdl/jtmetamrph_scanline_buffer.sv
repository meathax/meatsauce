//
//
// Copyright (c) 2012-2013 Ludvig Strigeus
// Copyright (c) 2017,2018 Sorgelig
//
// This program is GPL Licensed. See COPYING for the full license.
//
//
////////////////////////////////////////////////////////////////////////////////////////////////////////

// Nearest-neighbour line doubling. The four-phase input pipeline and read
// latency match the former disabled filter; each stored pixel replaces four
// identical subpixels. No interpolation table or arithmetic is instantiated.
module metamorphic_scanline_buffer #(parameter LENGTH=388, HALF_DEPTH=0, parameter AWIDTH=$clog2(LENGTH)-1, DWIDTH=HALF_DEPTH ? 11 : 23)(
 input clk, ce_in, input [DWIDTH:0] inputpixel,
 input reset_frame,reset_line,ce_out,input [1:0] read_y,input hblank,
 output [DWIDTH:0] outpixel
);
reg curbuf;
reg [1:0] cyc;
reg [AWIDTH:0] offs,wrin_addr2;
reg [DWIDTH:0] wrpix,Curr0,Curr1,Curr2;
reg wrin_en,wrout_en;
reg [AWIDTH+1:0] read_x,wrout_addr;
reg [DWIDTH:0] pipe0,pipe1,pipe2,pipe3,wrdata,pixel_q;
wire [DWIDTH:0] input_q0,input_q1,stored_pixel;
metamorphic_scanline_ram #(.NUMWORDS(LENGTH),.AWIDTH(AWIDTH),.DWIDTH(DWIDTH)) buf0
 (clk,wrpix,offs,wrin_addr2,wrin_en && curbuf,input_q0);
metamorphic_scanline_ram #(.NUMWORDS(LENGTH),.AWIDTH(AWIDTH),.DWIDTH(DWIDTH)) buf1
 (clk,wrpix,offs,wrin_addr2,wrin_en && !curbuf,input_q1);
wire [DWIDTH:0] current_pixel = curbuf ? input_q1 : input_q0;
metamorphic_scanline_ram #(.NUMWORDS(LENGTH*2),.AWIDTH(AWIDTH+1),.DWIDTH(DWIDTH)) line_out
 (clk,wrdata,{read_x[AWIDTH+1:1],read_y[1]},wrout_addr,wrout_en,stored_pixel);
assign outpixel=pixel_q;
always @(posedge clk) begin
 if(ce_out) begin
  if(read_x[0]) pixel_q<=stored_pixel;
  if(~hblank & ~&read_x) read_x<=read_x+1'd1;
  if(hblank) read_x<=0;
 end
 if(ce_in) begin
  pipe0<=Curr0;pipe1<=pipe0;pipe2<=pipe1;pipe3<=pipe2;
 end
end
always @(posedge clk) begin
 reg old_reset_line,old_reset_frame;
 reg [3:0] wrdata_finished;
 reg [AWIDTH+1:0] waddr;
 wrout_en<=0;wrin_en<=0;
 if(ce_in) begin
  if(cyc==0) wrdata<=pipe3;
  wrdata_finished<=wrdata_finished<<1;
  if(wrdata_finished[3]) begin wrout_en<=1;wrout_addr<=waddr;end
  if(~&offs) begin
   if(cyc==1) begin
    Curr2<=current_pixel;wrpix<=inputpixel;wrin_addr2<=offs;wrin_en<=1;
   end
   if(cyc==3) begin
    offs<=offs+1'd1;waddr<={offs,curbuf};wrdata_finished[0]<=1;
   end
  end
  if(cyc==3) begin Curr0<=Curr1;Curr1<=Curr2;end
  cyc<=cyc+1'b1;
  if(old_reset_line && ~reset_line) begin
   old_reset_frame<=reset_frame;offs<=0;cyc<=0;curbuf<=~curbuf;
   Curr0<=0;Curr1<=0;Curr2<=0;
   if(old_reset_frame & ~reset_frame) begin curbuf<=0;end
  end
  old_reset_line<=reset_line;
 end
end
endmodule
module metamorphic_scanline_ram #(parameter NUMWORDS=388,AWIDTH=8,DWIDTH=23)(
 input clock,input [DWIDTH:0] data,input [AWIDTH:0] rdaddress,wraddress,
 input wren,output reg [DWIDTH:0] q
);
reg [DWIDTH:0] ram[0:NUMWORDS-1];
always @(posedge clock) begin
 if(wren) ram[wraddress]<=data;
 q<=ram[rdaddress];
end
endmodule
