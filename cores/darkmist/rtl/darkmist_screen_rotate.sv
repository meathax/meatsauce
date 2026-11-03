//============================================================================
//
//  Copyright (C) 2020 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
// Copyright (C) 2026 Darkmist contributors; changes under GPL-2.0-or-later.
// Project derivative of sys/arcade_video.v screen_rotate, Template commit
// 3ea1134cf05d62c2b1db30362277a823d739ced2. Original sys is preserved.
// Geometry/format are upstream-compatible; transport and ownership rewritten.
module darkmist_screen_rotate #(
 parameter MEM_BASE=7'b0010010, parameter FIFO_BITS=8
)(
 input CLK_VIDEO, reset, CE_PIXEL,
 input [7:0] VGA_R,VGA_G,VGA_B,
 input VGA_HS,VGA_VS,VGA_DE,rotate_ccw,no_rotate,flip,
 output video_rotated, FB_EN,
 output [4:0] FB_FORMAT,
 output reg [11:0] FB_WIDTH,FB_HEIGHT,
 output [31:0] FB_BASE, output reg [13:0] FB_STRIDE,
 input FB_VBL,FB_LL,
 output DDRAM_CLK,input DDRAM_BUSY,
 output [7:0] DDRAM_BURSTCNT,output [28:0] DDRAM_ADDR,
 output [63:0] DDRAM_DIN,output [7:0] DDRAM_BE,
 output DDRAM_WE,DDRAM_RD
);
 localparam DEPTH=1<<FIFO_BITS;
 // Entry is {bank, byte-address, BGR888}. A frame retains its bank until
 // every queued transaction is accepted; BUSY never changes the head.
 reg [48:0] fifo[0:DEPTH-1];
 reg [FIFO_BITS-1:0] rdptr,wrptr;
 reg [FIFO_BITS:0] count;
 wire pop=count!=0 && !DDRAM_BUSY;
 wire [48:0] head=fifo[rdptr];
 assign DDRAM_CLK=CLK_VIDEO;
 assign DDRAM_BURSTCNT=1;
 assign DDRAM_ADDR={MEM_BASE,head[48:47],head[46:27]};
 assign DDRAM_DIN={{8'd0,head[23:0]},{8'd0,head[23:0]}};
 assign DDRAM_BE=head[26] ? 8'hF0 : 8'h0F;
 assign DDRAM_WE=count!=0;
 assign DDRAM_RD=0;
 assign FB_FORMAT=5'b00110;
 assign video_rotated=~no_rotate;
 reg enabled,display_valid,pending_valid,capture,ending,bad;
 reg [1:0] display_bank,pending_bank,capture_bank;
 assign FB_EN=enabled && display_valid;
 assign FB_BASE={MEM_BASE,display_bank,23'd0};
 reg [11:0] measured_w,measured_h,mx,my;
 reg old_de,old_vs,old_vbl;
 reg [11:0] width,height,x,y;
 reg [13:0] stride,pending_stride;
 reg [11:0] pending_width,pending_height;
 reg mode_ccw,mode_flip;
 reg [23:0] pixels;
 wire active=(!no_rotate || flip);
 wire vsrise=CE_PIXEL && VGA_VS && !old_vs;
 wire derise=CE_PIXEL && VGA_DE && !old_de;
 wire defall=CE_PIXEL && !VGA_DE && old_de;
 wire push=CE_PIXEL && VGA_DE && capture && !ending && !bad;
 wire room=count<DEPTH || pop;
 reg [22:0] address;
 always @* begin
   if(mode_flip) address=(height-1-y)*stride+(width-1-x)*4;
   else if(mode_ccw) address=(width-1-x)*stride+y*4;
   else address=x*stride+(height-1-y)*4;
 end
 function [1:0] free_bank;
 input [1:0] a,b; input av,bv;
 begin
   if((!av || a!=0) && (!bv || b!=0)) free_bank=0;
   else if((!av || a!=1) && (!bv || b!=1)) free_bank=1;
   else free_bank=2;
 end
 endfunction
 always @(posedge CLK_VIDEO) begin
  if(reset) begin
   rdptr<=0;wrptr<=0;count<=0;enabled<=0;display_valid<=0;
   pending_valid<=0;capture<=0;ending<=0;bad<=0;
   display_bank<=0;pending_bank<=1;capture_bank<=2;
   old_de<=0;old_vs<=0;old_vbl<=0;
   measured_w<=0;measured_h<=0;mx<=0;my<=0;
   width<=0;height<=0;x<=0;y<=0;pixels<=0;
   stride<=0;FB_WIDTH<=0;FB_HEIGHT<=0;FB_STRIDE<=0;
   pending_width<=0;pending_height<=0;pending_stride<=0;
   mode_ccw<=0;mode_flip<=0;
  end else begin
   old_vbl<=FB_VBL;
   if(CE_PIXEL) begin
    old_de<=VGA_DE;old_vs<=VGA_VS;
    if(VGA_DE) mx<=derise ? 1 : mx+1'b1;
    if(derise) my<=my+1'b1;
    if(defall) measured_w<=mx;
    if(vsrise) begin measured_h<=my;my<=0;end
   end
   if(pop) rdptr<=rdptr+1'b1;
   if(push && room) begin
    fifo[wrptr]<={capture_bank,address,VGA_B,VGA_G,VGA_R};
    wrptr<=wrptr+1'b1;
   end
   case({push && room,pop})
    2'b10:count<=count+1'b1;
    2'b01:count<=count-1'b1;
    default:count<=count;
   endcase
   if(push) begin
    if(!room || x>=width || y>=height) bad<=1;
    x<=x+1'b1;pixels<=pixels+1'b1;
   end
   if(defall && capture && !ending) begin
    if(x!=width) bad<=1;
    x<=0;y<=y+1'b1;
   end
   // Completion follows the last *accepted* write. Invalid/overflow frames
   // drain safely, then lose capture ownership without becoming pending.
   if(capture && ending && count==0) begin
    capture<=0;ending<=0;
    if(!bad && pixels==width*height && !pending_valid) begin
     pending_valid<=1;pending_bank<=capture_bank;
     pending_width<=mode_flip ? width : height;
     pending_height<=mode_flip ? height : width;
     pending_stride<=stride;
    end
   end
   if(vsrise) begin
    // At the next VS the actual frame height/line lengths are known. Never
    // infer completion merely from receiving the expected last pixel.
    if(capture && !ending) begin
     if(my!=height || pixels!=width*height) bad<=1;
     ending<=1;
     if(count==0) begin
      capture<=0;ending<=0;
      if(!bad && my==height && pixels==width*height && !pending_valid) begin
       pending_valid<=1;pending_bank<=capture_bank;
       pending_width<=mode_flip ? width : height;
       pending_height<=mode_flip ? height : width;
       pending_stride<=stride;
      end
      if(active && measured_w!=0 && my!=0) begin
       capture<=1;bad<=0;pixels<=0;x<=0;y<=0;
       // If this completed frame becomes pending, exclude its bank.
       capture_bank<=free_bank(display_bank,
        pending_valid ? pending_bank : capture_bank,display_valid,
        pending_valid || (!bad && my==height && pixels==width*height));
       width<=measured_w;height<=my;
       mode_ccw<=rotate_ccw;mode_flip<=no_rotate && flip;
       stride<=((no_rotate && flip ? measured_w : my)+3)/4*16;
      end
     end
    end
    if(!capture && active && measured_w!=0 && my!=0) begin
     capture<=1;ending<=0;bad<=0;pixels<=0;x<=0;y<=0;
     capture_bank<=free_bank(display_bank,pending_bank,display_valid,pending_valid);
     width<=measured_w;height<=my;
     mode_ccw<=rotate_ccw;mode_flip<=no_rotate && flip;
     stride<=((no_rotate && flip ? measured_w : my)+3)/4*16;
    end
   end
   // LL requests earliest complete publication, also at VBL. It cannot
   // weaken ownership or completeness; overload repeats the last frame.
   if(FB_VBL && !old_vbl) begin
    enabled<=active;
    if(pending_valid) begin
     display_bank<=pending_bank;display_valid<=1;pending_valid<=0;
     FB_WIDTH<=pending_width;FB_HEIGHT<=pending_height;FB_STRIDE<=pending_stride;
    end
   end
  end
 end
endmodule
