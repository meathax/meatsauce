// SPDX-License-Identifier: GPL-3.0-or-later
// Controls are committed together at native vblank. Output cadence stays /8.
module dfjail_crt(
 input clk,reset,ce_in,enable,
 input [2:0] hsize_option,
 input signed [4:0] hpos_option,vpos_option,
 input [23:0] rgb_in,input hs_in,vs_in,hb_in,vb_in,
 output reg ce_out,output reg active,
 output [23:0] rgb_out,output hs_out,vs_out,hb_out,vb_out
);
reg old_blank;
reg signed [4:0] size_step;
reg signed [8:0] hpos;
reg signed [5:0] vpos;
always @(posedge clk)begin
 if(reset)begin active<=0;old_blank<=0;size_step<=0;hpos<=0;vpos<=0;ce_out<=0;end
 else begin
  ce_out<=ce_in;
  if(ce_in)begin
   old_blank<=vb_in;
   if(vb_in && !old_blank)begin
    active<=enable;
    case(hsize_option)1:size_step<=1;2:size_step<=2;3:size_step<=-2;4:size_step<=-1;default:size_step<=0;endcase
    hpos<={{4{hpos_option[4]}},hpos_option};
    vpos<={vpos_option[4],vpos_option};
   end
  end
 end
end
dfjail_crt_adjust #(.HTOTAL(400),.VTOTAL(262),.HPOS_MODE(1),.SEPARATE_BLANK(1)) adjust(
 .clk(clk),.reset(reset),.pxl_cen(ce_in),.pxl2_cen(ce_in),.active(active),
 .hsize(size_step),.hoffset(hpos),.voffset(vpos),
 .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
 .hs_in(hs_in),.vs_in(vs_in),.hb_in(hb_in),.vb_in(vb_in),
 .r_out(rgb_out[23:16]),.g_out(rgb_out[15:8]),.b_out(rgb_out[7:0]),
 .hs_out(hs_out),.vs_out(vs_out),.hb_out(hb_out),.vb_out(vb_out),.hs_ref_out()
);
endmodule
