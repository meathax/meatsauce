// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate fixed-cadence CRT geometry. Changes take effect at vblank.
// Address resampling does not change the pixel clock enable.
module spinal_crt(
 input wire clk,reset,ce_in,enable,
 input wire [2:0] hsize_option,
 input wire signed [4:0] hpos_option,vpos_option,
 input wire [23:0] rgb_in,input wire hs_in,vs_in,hb_in,vb_in,
 output reg ce_out,output reg active,
 output wire [23:0] rgb_out,output wire hs_out,vs_out,hb_out,vb_out
);
 reg old_blank,old_hblank,pending,pending_enable,sync_active,vs_previous,seen_vs;
 reg [7:0] lines_since_vs;reg signed [4:0] size_step;
 reg signed [8:0] hpos;reg signed [5:0] vpos,pending_vpos;wire transition_safe;
 // All supported shifts differ by at most 31 lines. Switching in this window
 // after the last VSync rising edge leaves the next edge 225..287 lines away.
 wire transition_commit=ce_in && pending && !hb_in && old_hblank && seen_vs &&
                        lines_since_vs>=8'd192 && lines_since_vs<=8'd208 && transition_safe;
 always @(posedge clk)begin
  if(reset)begin active<=0;old_blank<=0;old_hblank<=1;pending<=0;pending_enable<=0;pending_vpos<=0;sync_active<=0;vs_previous<=0;seen_vs<=0;lines_since_vs<=0;size_step<=0;hpos<=0;vpos<=0;ce_out<=0;end
  else begin
   ce_out<=ce_in;
   if(ce_in)begin
    old_blank<=vb_in;old_hblank<=hb_in;
    vs_previous<=vs_out;
    if(vs_out && !vs_previous)begin lines_since_vs<=0;seen_vs<=1;end
    else if(!hb_in && old_hblank && lines_since_vs!=8'hff)lines_since_vs<=lines_since_vs+1'b1;
    if(vb_in && !old_blank)begin
     active<=enable;pending<=1;pending_enable<=enable;pending_vpos<={vpos_option[4],vpos_option};
     case(hsize_option)1:size_step<=1;2:size_step<=2;3:size_step<=-2;4:size_step<=-1;default:size_step<=0;endcase
     hpos<={{4{hpos_option[4]}},hpos_option};
    end
    if(transition_commit)begin
     sync_active<=pending_enable;vpos<=pending_vpos;pending<=0;
    end
   end
  end
 end
 spinal_crt_linebuffer #(.HTOTAL(472),.VTOTAL(256),.HPOS_MODE(1),.SEPARATE_BLANK(1)) adjust(
  .clk(clk),.reset(reset),.pxl_cen(ce_in),.pxl2_cen(ce_in),.active(active),
  .hsize(size_step),.hoffset(hpos),.voffset(vpos),.pending_voffset(pending_vpos),.pending_active(pending_enable),.transition_commit(transition_commit),.sync_active(sync_active),.transition_safe(transition_safe),
  .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),.hs_in(hs_in),.vs_in(vs_in),.hb_in(hb_in),.vb_in(vb_in),
  .r_out(rgb_out[23:16]),.g_out(rgb_out[15:8]),.b_out(rgb_out[7:0]),.hs_out(hs_out),.vs_out(vs_out),.hb_out(hb_out),.vb_out(vb_out),.hs_ref_out()
 );
endmodule
