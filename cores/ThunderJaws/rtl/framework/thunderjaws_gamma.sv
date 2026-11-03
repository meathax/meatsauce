// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer gamma_fast's three parallel channel tables with a fixed full-rate
// tuple pipeline. Pixel-sampled sync would quantize the VAD half-pixel HS.
module thunderjaws_gamma(
 input wire clk_sys,init_reset,ce_in,de_in,hb_in,vb_in,hs_in,vs_in,
 input wire [23:0] rgb_in,
 inout wire [21:0] gamma_bus,
 output reg ce_out,de_out,hb_out,vb_out,hs_out,vs_out,
 output reg [23:0] rgb_out
);
 assign gamma_bus[21]=1'b1;
 wire enabled=gamma_bus[19],wr=gamma_bus[18];
 wire [9:0] address=gamma_bus[17:8];wire [7:0] value=gamma_bus[7:0];
 reg [7:0] red[0:255],green[0:255],blue[0:255];
 integer i;initial for(i=0;i<256;i=i+1)begin red[i]=8'(i);green[i]=8'(i);blue[i]=8'(i);end
 reg [23:0] pixel0,pixel1,corrected;
 reg [1:0] ce_pipe,de_pipe,hb_pipe,vb_pipe,en_pipe,hs_pipe,vs_pipe;
 always @(posedge clk_sys)begin
  if(wr)case(address[9:8])0:red[address[7:0]]<=value;1:green[address[7:0]]<=value;2:blue[address[7:0]]<=value;default:;endcase
  if(ce_in)pixel0<=rgb_in;
  if(ce_pipe[0])begin
   pixel1<=pixel0;
   // Explicit same-address write forwarding, no RAM collision waiver.
   corrected[23:16]<=wr && address[9:8]==0 && address[7:0]==pixel0[23:16] ? value : red[pixel0[23:16]];
   corrected[15:8]<=wr && address[9:8]==1 && address[7:0]==pixel0[15:8] ? value : green[pixel0[15:8]];
   corrected[7:0]<=wr && address[9:8]==2 && address[7:0]==pixel0[7:0] ? value : blue[pixel0[7:0]];
  end
  ce_pipe<={ce_pipe[0],ce_in};ce_out<=ce_pipe[1];
  de_pipe<={de_pipe[0],de_in};hb_pipe<={hb_pipe[0],hb_in};vb_pipe<={vb_pipe[0],vb_in};en_pipe<={en_pipe[0],enabled};
  hs_pipe<={hs_pipe[0],hs_in};vs_pipe<={vs_pipe[0],vs_in};hs_out<=hs_pipe[1];vs_out<=vs_pipe[1];
  if(ce_pipe[1])begin
   de_out<=de_pipe[1];hb_out<=hb_pipe[1];vb_out<=vb_pipe[1];
   rgb_out<=de_pipe[1] ? (en_pipe[1] ? corrected : pixel1) : 24'd0;
  end
  if(init_reset)begin
   ce_pipe<=0;de_pipe<=0;hb_pipe<=3;vb_pipe<=3;en_pipe<=0;hs_pipe<=0;vs_pipe<=0;
   pixel0<=0;pixel1<=0;corrected<=0;ce_out<=0;de_out<=0;hb_out<=1;vb_out<=1;hs_out<=0;vs_out<=0;rgb_out<=0;
  end
 end
endmodule
