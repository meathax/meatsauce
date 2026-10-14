// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioral translation of MAME artmagic_v.cpp (BSD-3-Clause,
// Aaron Giles/Nicola Salmoria). Sequential memory interface: hold until ack.
// Register writes are backpressured while busy: no silently lost retriggers.
// Source words are fetched from SDRAM; pixels go to the on-chip VRAM port
// (one clock each, never refused) as {page,row,col} word indices.
`default_nettype none
module stone_blitter(
 input wire clk,reset,reg_wr,input wire [2:0] reg_addr,
 input wire [15:0] reg_data,input wire [1:0] reg_be,
 output wire reg_ready,output wire [15:0] status,
 output reg req,output reg we,output reg [22:0] addr,
 output reg [15:0] wdata,input wire ack,input wire [15:0] rdata,
 output reg vram_we,output reg [17:0] vram_addr,output reg [7:0] vram_data,
  output wire busy,input wire [1:0] game,output wire cache_enable);
 reg [15:0] regs[0:7];
 reg page,dest_page;
 localparam IDLE=0,ROW=1,FETCH=2,PIXEL=3,ENDROW=6;
 reg [3:0] state;
 reg [20:0] source;
 reg [8:0] groups,height,row,group_no;
 reg signed [17:0] sx,sy;
 reg [7:0] mx,my;
 reg [3:0] color,feed;
 reg [15:0] packed_pixels,pf_data;reg pf_valid;
 wire [15:0] word=pf_valid ? pf_data:rdata;
 reg [1:0] nibble;
 wire [15:0] merged={(reg_be[1] ? reg_data[15:8]:regs[reg_addr][15:8]),(reg_be[0] ? reg_data[7:0]:regs[reg_addr][7:0])};
 // game: 0 Stone Ball, 1 Ultimate Tennis (same cipher), 2 Cheese Chase.
 // Stone Ball leaves one-line blits unencrypted; the source ROM address wraps
 // at the game's graphics ROM size, as MAME masks with region length - 1.
 wire cheese=game==2'd2, stone=game==2'd0;
 function automatic [15:0] xor_key(input c,input [3:0] f);
   xor_key=c ? (16'h0891 ^ (f[0] ? 16'h1100:16'd0) ^ (f[1] ? 16'h0022:16'd0) ^ (f[2] ? 16'h0440:16'd0) ^ (f[3] ? 16'h8008:16'd0))
             : (16'h0462 ^ (f[0] ? 16'h0011:16'd0) ^ (f[1] ? 16'h2200:16'd0) ^ (f[2] ? 16'h4004:16'd0) ^ (f[3] ? 16'h0880:16'd0));
 endfunction
 wire [15:0] decrypted=packed_pixels ^ ((height==1 && stone) ? 16'd0:xor_key(cheese,feed));
 wire [20:0] src_mask=stone ? 21'h1fffff : (cheese ? 21'h07ffff : 21'h0fffff);
 wire [15:0] d0_inc=regs[0]+16'd1;
 wire feed2=stone ? regs[0][5] : d0_inc[6];
 wire [3:0] value=decrypted[{nibble,2'b00} +: 4];
 wire [7:0] dropmask=mx << {group_no[1:0],1'b0};
 wire drop_pixel=(nibble==0 && dropmask[7]) || (nibble==2 && dropmask[6]);
 wire [7:0] rowmask=my << row[3:1];
  assign busy=state!=IDLE;
  // Cache only bounded sprites. Large cold streams keep the direct SDRAM
  // path, avoiding lookup/fill latency on backgrounds and long scan lines.
  assign cache_enable=groups<=9'd8 && height<=9'd32;
 assign reg_ready=!busy;
 assign status=(16'hffef | {11'd0,page,4'd0}) ^ (busy ? 16'd6:16'd0);
 integer k;
 always @(posedge clk) begin
   if(reset) begin
     state<=IDLE;req<=0;we<=0;addr<=0;pf_data<=0;pf_valid<=0;wdata<=0;page<=0;dest_page<=0;vram_we<=0;vram_addr<=0;vram_data<=0;
     source<=0;groups<=0;height<=0;row<=0;group_no<=0;sx<=0;sy<=0;mx<=0;my<=0;color<=0;feed<=0;packed_pixels<=0;nibble<=0;
     for(k=0;k<8;k=k+1) regs[k]<=0;
   end else begin
   vram_we<=0;
   // A source request completes here; FETCH consumes it at once, otherwise
   // the prefetched word is kept until the next group needs it.
   if(req && ack) begin req<=0;pf_data<=rdata;pf_valid<=state!=FETCH && state!=ENDROW;end
   case(state)
     IDLE: if(reg_wr) begin
       regs[reg_addr]<=merged;
       if(reg_addr==4) page<=reg_data[1];
       if(reg_addr==3) begin
         source<={regs[1][4:0],regs[0]}; groups<={1'b0,regs[7][7:0]}+9'd1;
         height<={1'b0,regs[7][15:8]}+9'd1; row<=0;
         sy<={{2{merged[15]}},merged}; mx<=regs[6][7:0]; my<=regs[6][15:8];color<=regs[1][11:8];dest_page<=~page;state<=ROW;
       end
     end
     ROW: begin
       group_no<=0;sx<={{2{regs[2][15]}},regs[2]};
       feed<={regs[0][13],feed2,regs[7][10],regs[7][0]};
       if((!row[0] && rowmask[7]) || sy<0 || sy>=256) state<=ENDROW;
       else begin req<=1;addr<=23'h040000+{2'b0,source & src_mask};state<=FETCH;end
     end
     // Wait for this group's source word: the prefetched word, or the
     // outstanding request's data. The next group's word is prefetched while
     // this group's four pixels are processed.
     FETCH: if(pf_valid || ack) begin
       packed_pixels<=word;nibble<=0;pf_valid<=0;
       if(group_no==0 && row!=0) feed<=4'hc ^ {word[11:10],2'b0} ^ word[15:12];
       if(sx>=508) state<=ENDROW;else state<=PIXEL;
     end
     PIXEL: begin
       // Prefetch on the first pixel, so the request line drops for one
       // clock between consecutive requests.
       if(nibble==0 && group_no+9'd1!=groups) begin req<=1;addr<=23'h040000+{2'b0,((source+{{12{1'b0}},group_no}+21'd1) & src_mask)};end
       feed<=value;
       if(!drop_pixel) sx<=sx+18'sd1;
       if(!drop_pixel && value!=0 && sx>=0 && sx<512) begin
         vram_we<=1;vram_addr<={dest_page,sy[7:0],sx[8:0]};vram_data<={color,value};
       end
       if(nibble==3) begin
         if(group_no+9'd1==groups) state<=ENDROW;
         else begin group_no<=group_no+1'b1;state<=FETCH;end
       end else nibble<=nibble+1'b1;
     end
     // An abandoned prefetch (sx >= 508) completes before the next row.
     ENDROW: if(!req) begin
       if(row[0] || !rowmask[7]) sy<=sy+18'sd1;
       source<=source+{{12{1'b0}},groups};row<=row+1'b1;
       if(row+9'd1==height) state<=IDLE;else state<=ROW;
     end
     default:state<=IDLE;
   endcase
   end
 end
endmodule
`default_nettype wire
