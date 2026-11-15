// SPDX-License-Identifier: GPL-3.0-or-later
// Composed-pixel reversal, preserving original public pixel enable and timing.
// Write/count uses the original registered response tag with matching RGB/HB.
module snk_hsj_presentation180_linebuffer(
 input wire clk,reset,enable,input wire[7:0]profile,
 input wire ce_pre,ce_response,hblank,vblank,
 input wire[11:0]rgb_in,output wire[11:0]rgb_out,
 output wire primed);
 (* ramstyle="M10K, no_rw_check" *) reg[11:0]line_ram[0:1023];
 reg[11:0]read_q,reverse_rgb;
 reg write_bank;
 reg[1:0]bank_valid;
 reg[8:0]x;
 reg hb_previous,enable_previous;
 reg[7:0]profile_previous;
 wire[8:0]reverse_x=9'd287-x;
 assign primed=bank_valid[!write_bank];
 assign rgb_out=enable?reverse_rgb:rgb_in;
 always @(posedge clk)begin
  // x advances one root edge AFTER each original public CE/RGB publication.
  // It therefore prefetches the next public x at least one full edge in advance.
  read_q<=line_ram[{!write_bank,reverse_x}];
  if(reset || profile!=profile_previous || enable!=enable_previous)begin
   write_bank<=0;bank_valid<=0;x<=0;hb_previous<=1;reverse_rgb<=0;
  end else begin
   if(hblank || vblank)reverse_rgb<=0;
   // All three signals here are the SAME registered response epoch.
   if(ce_response)begin
    hb_previous<=hblank;
    if(hblank)begin
     if(!hb_previous)begin
      bank_valid[write_bank]<=(x==9'd288);
      write_bank<=!write_bank;
     end
     x<=0;
    end else begin
     line_ram[{write_bank,x}]<=rgb_in;
     x<=x+1'b1;
    end
   end
   // Read publishes on the unchanged original CE edge. PRE-HB can include
   // the extra blank-assertion edge; that output is publicly blank and is
   // never written/counted. No crop or relaxed complete-line guard.
   if(ce_pre && !hblank && !vblank)
    reverse_rgb<=primed?read_q:12'b0;
  end
  profile_previous<=profile;enable_previous<=enable;
 end
endmodule
