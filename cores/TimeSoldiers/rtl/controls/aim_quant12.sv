// SPDX-License-Identifier: GPL-3.0-or-later
// SNK signed {Y,X} convention, Y down, four interleaved stick channels.
// Native twelve-direction games: 0=N,3=E,6=S,9=W. Centring retains dir.
module aim_quant12(
 input wire clk, reset,
 input wire [63:0] ana,
 input wire [23:0] thr,
 output reg [3:0] defl=0,
 output reg [15:0] dir=0,
 output reg [3:0] upd=0
);
 reg [1:0] channel=0;
 reg [7:0] x,y,ax,ay,major,minor;
 reg [5:0] threshold;
 reg [8:0] radius,release_threshold;
 reg [23:0] ratio,boundary;
 reg [3:0] q,target;
 always @* begin
  x=ana[channel*16+:8];y=ana[channel*16+8+:8];
  ax=x[7] ? (x==8'h80 ? 8'd127 : 8'd0-x) : x;
  ay=y[7] ? (y==8'h80 ? 8'd127 : 8'd0-y) : y;
  major=ax>=ay ? ax:ay;minor=ax>=ay ? ay:ax;
  threshold=thr[channel*6+:6];
  radius={1'b0,major}+({1'b0,minor}>>1);
  release_threshold={3'd0,threshold}-({3'd0,threshold}>>2);
  // Q16 tan(15deg), exact nearest-sector result for every signed8-bit pair.
  ratio={minor,16'd0};boundary=major*24'd17560;
  if(ratio<=boundary) q=ax>=ay ? 3:0;
  else if(ax==ay) q=(x[7]!=y[7]) ? 2:1;
  else q=ax>ay ? 2:1;
  if(!x[7] && y[7]) target=q;
  else if(!x[7] && !y[7]) target=6-q;
  else if(x[7] && !y[7]) target=6+q;
  else target=q==0 ? 0:12-q;
 end
 always @(posedge clk) begin
  channel<=channel+1'b1;upd<=0;
  if(reset)begin channel<=0;defl<=0;dir<=0;end
  else if(radius>0 && radius >= (defl[channel] ? release_threshold:{3'd0,threshold}))begin
   defl[channel]<=1;dir[channel*4+:4]<=target;upd[channel]<=1;
  end else defl[channel]<=0;
 end
endmodule
