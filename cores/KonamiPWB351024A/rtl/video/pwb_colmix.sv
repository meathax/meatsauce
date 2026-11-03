// SPDX-License-Identifier: GPL-3.0-or-later
// PWB351024A palette and priority from MAME 0.289 mainevt.cpp.
module pwb_colmix (
 input logic clk,reset,pxl_cen,video_enable,game_mainevt,
 input logic lhbl,lvbl,hs,vs,
 input logic [8:0] hdump,vdump,
 input logic cpu_we,
 input logic [8:0] cpu_addr,
 input logic [7:0] cpu_dout,
 output logic [7:0] cpu_din,
 input logic [7:0] f_pxl,
 input logic [11:0] a_pxl,b_pxl,o_pxl,
 input logic f_blank_n,b_blank_n,o_blank_n,shadow,
 output logic [7:0] red,green,blue,
 output logic out_cen,out_hs,out_vs,out_lhbl,out_lvbl,
 output logic [8:0] out_hdump,out_vdump,
 output logic [7:0] palette_index
);
 logic [7:0] hi[0:255],lo[0:255];
 logic [7:0] index;
 logic sprite_visible,shade;
 integer n;
 initial for(n=0;n<256;n=n+1) begin hi[n]=0;lo[n]=0;end
 // K051960's effective palette retains priority bits 5/6 in pixel bits 9/10.
 // Main Event: foreground always above sprite. Layer B category 1 (color5)
 // blocks HALF sprites; both B categories block LOW sprites.
 always @* begin
  shade=0;
  index={2'b00,a_pxl[5:4],a_pxl[3:0]};
  if(game_mainevt) index=index+8'd128;
  if(b_blank_n) index={2'b01,b_pxl[5:4],b_pxl[3:0]};
  sprite_visible=o_blank_n || shadow;
  if(game_mainevt && b_blank_n)
   sprite_visible=(o_blank_n || shadow) && (o_pxl[9] || (o_pxl[10] && b_pxl[7]));
  if(sprite_visible && shadow) shade=1;
  if(sprite_visible && (!shadow || o_blank_n)) index=game_mainevt ? {2'b11,o_pxl[5:4],o_pxl[3:0]} : {1'b1,o_pxl[6:4],o_pxl[3:0]};
  if(f_blank_n) begin index={2'b00,f_pxl[5:4],f_pxl[3:0]};shade=0;end
 end
    function automatic [7:0] expand(input [4:0] component,input dim);
        logic [7:0] shadow;
        begin
            // Exact floor(0.6 * {component,component[4:2]}) without a divider.
            case(component)
                5'd0: shadow=8'd0;
                5'd1: shadow=8'd4;
                5'd2: shadow=8'd9;
                5'd3: shadow=8'd14;
                5'd4: shadow=8'd19;
                5'd5: shadow=8'd24;
                5'd6: shadow=8'd29;
                5'd7: shadow=8'd34;
                5'd8: shadow=8'd39;
                5'd9: shadow=8'd44;
                5'd10: shadow=8'd49;
                5'd11: shadow=8'd54;
                5'd12: shadow=8'd59;
                5'd13: shadow=8'd64;
                5'd14: shadow=8'd69;
                5'd15: shadow=8'd73;
                5'd16: shadow=8'd79;
                5'd17: shadow=8'd84;
                5'd18: shadow=8'd88;
                5'd19: shadow=8'd93;
                5'd20: shadow=8'd99;
                5'd21: shadow=8'd103;
                5'd22: shadow=8'd108;
                5'd23: shadow=8'd113;
                5'd24: shadow=8'd118;
                5'd25: shadow=8'd123;
                5'd26: shadow=8'd128;
                5'd27: shadow=8'd133;
                5'd28: shadow=8'd138;
                5'd29: shadow=8'd143;
                5'd30: shadow=8'd148;
                5'd31: shadow=8'd153;
                default: shadow=8'hxx;
            endcase
            expand=dim ? shadow : {component,component[4:2]};
        end
    endfunction
 wire [15:0] colour={hi[index],lo[index]};
 always_ff @(posedge clk) begin
  if(cpu_we) begin if(cpu_addr[0]) lo[cpu_addr[8:1]]<=cpu_dout;else hi[cpu_addr[8:1]]<=cpu_dout;end
  cpu_din<=cpu_addr[0]?lo[cpu_addr[8:1]]:hi[cpu_addr[8:1]];
  out_cen<=pxl_cen;
  if(reset) begin red<=0;green<=0;blue<=0;out_cen<=0;out_hs<=0;out_vs<=0;out_lhbl<=0;out_lvbl<=0;out_hdump<=0;out_vdump<=0;palette_index<=0;end
  else if(pxl_cen) begin
   palette_index<=index;
   red<=video_enable?expand(colour[4:0],shade):8'd0;
   green<=video_enable?expand(colour[9:5],shade):8'd0;
   blue<=video_enable?expand(colour[14:10],shade):8'd0;
   out_hs<=hs;out_vs<=vs;out_lhbl<=lhbl;out_lvbl<=lvbl;out_hdump<=hdump;out_vdump<=vdump;
  end
 end
endmodule
