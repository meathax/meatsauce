// SPDX-License-Identifier: GPL-3.0-or-later
// SNK donor conventions: four interleaved signed {Y,X} channels, Y down,
// octagonal radial deadzone, 75% radial release and retained centred target.
// Sixteen clockwise sectors: 0=N,4=E,8=S,12=W. Integer ratio boundaries
// approximate tan(11.25deg) and tan(33.75deg) within 0.05 degrees.
// Three-stage pipeline (abs/major-minor, radius/ratio/boundaries, decision).
// Each channel is evaluated every 4 clocks and its state is written 3 clocks
// after it is sampled, so hysteresis always sees the previous result.
module aim_quant16(
 input wire clk, reset,
 input wire [63:0] ana,
 input wire [23:0] thr,
 output reg [3:0] defl = 0,
 output reg [15:0] dir = 0,
 output reg [3:0] upd = 0
);
 reg [1:0] channel = 0;
 reg [1:0] region [0:3];
 integer i;
 function automatic [16:0] scale(input [7:0] value,input [7:0] coefficient);
  integer bitno;
  begin
   scale=0;
   for(bitno=0;bitno<8;bitno=bitno+1)
    if(coefficient[bitno]) scale=scale+({9'd0,value}<<bitno);
  end
 endfunction
 // Stage 1
 reg v1=0; reg [1:0] c1=0; reg sx1=0,sy1=0,xge1=0; reg [7:0] major1=0,minor1=0; reg [5:0] thr1=0;
 wire [7:0] x=ana[channel*16+:8], y=ana[channel*16+8+:8];
 wire [7:0] ax=x[7] ? (x==8'h80 ? 8'd127 : 8'd0-x) : x;
 wire [7:0] ay=y[7] ? (y==8'h80 ? 8'd127 : 8'd0-y) : y;
 // Stage 2
 reg v2=0; reg [1:0] c2=0; reg sx2=0,sy2=0,xge2=0; reg [5:0] thr2=0;
 reg [8:0] radius2=0,release2=0; reg [16:0] ratio2=0,s51=0,s171=0,s63=0,s39=0,s188=0,s155=0;
 // Stage 3
 reg [1:0] selected; reg [3:0] quadrant_angle,target;
 always @* begin
  selected=ratio2<=s51 ? 0 : ratio2<=s171 ? 1:2;
  if(defl[c2]) begin
   case(region[c2])
    0: if(ratio2<=s63) selected=0;
    1: if(ratio2>=s39 && ratio2<=s188) selected=1;
    2: if(ratio2>=s155) selected=2;
    default: ;
   endcase
  end
  quadrant_angle=xge2 ? 4-selected : selected;
  if(!sx2 && sy2) target=quadrant_angle;
  else if(!sx2 && !sy2) target=8-quadrant_angle;
  else if(sx2 && !sy2) target=8+quadrant_angle;
  else target=0-quadrant_angle;
 end
 always @(posedge clk) begin
  channel<=channel+1'b1;
  upd<=0;
  v1<=1; c1<=channel; sx1<=x[7]; sy1<=y[7]; xge1<=(ax>=ay);
  major1<=ax>=ay ? ax:ay; minor1<=ax>=ay ? ay:ax; thr1<=thr[channel*6+:6];
  v2<=v1; c2<=c1; sx2<=sx1; sy2<=sy1; xge2<=xge1; thr2<=thr1;
  radius2<={1'b0,major1}+({1'b0,minor1}>>1);
  release2<={3'd0,thr1}-({3'd0,thr1}>>2);
  ratio2<={1'b0,minor1,8'd0};
  s51<=scale(major1,8'd51); s171<=scale(major1,8'd171); s63<=scale(major1,8'd63);
  s39<=scale(major1,8'd39); s188<=scale(major1,8'd188); s155<=scale(major1,8'd155);
  if(reset) begin
   channel<=0; v1<=0; v2<=0; defl<=0; dir<=0;
   for(i=0;i<4;i=i+1) region[i]<=0;
  end else if(v2) begin
   if(radius2 >= (defl[c2] ? release2 : {3'd0,thr2})) begin
    defl[c2]<=1;
    dir[c2*4+:4]<=target;
    region[c2]<=selected;
    upd[c2]<=1;
   end else defl[c2]<=0;
  end
 end
endmodule
