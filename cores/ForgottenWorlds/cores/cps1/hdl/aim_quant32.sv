// SPDX-License-Identifier: GPL-3.0-or-later
// Two right-stick channels -> 32 clockwise sectors (0=N, 8=E, 16=S, 24=W).
// Same conventions as aim_quant16 (signed bytes {Y,X}, Y down, octagonal
// radial deadzone, 75% radial release, retained centred target) with
// 11.25-degree sectors and ~2.5-degree hysteresis on either side of a boundary.
// Nominal ratio boundaries tan(5.625,16.875,28.125,39.375)*256 = 25,78,137,210.
// Three-stage pipeline; each channel is evaluated every 2 clocks and its
// state is written 3 clocks after sampling, before its next decision.
module aim_quant32(
 input wire clk, reset,
 input wire [31:0] ana,        // {right2, right1}, each {Y[7:0],X[7:0]}
 input wire [11:0] thr,        // 6-bit radial threshold per channel
 output reg [1:0] defl = 0,
 output reg [9:0] dir = 0,     // 5-bit sector per channel
 output reg [1:0] upd = 0
);
 reg channel = 0;
 reg [2:0] region [0:1];
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
 reg v1=0,c1=0,sx1=0,sy1=0,xge1=0; reg [7:0] major1=0,minor1=0; reg [5:0] thr1=0;
 wire [7:0] x=ana[channel*16+:8], y=ana[channel*16+8+:8];
 wire [7:0] ax=x[7] ? (x==8'h80 ? 8'd127 : 8'd0-x) : x;
 wire [7:0] ay=y[7] ? (y==8'h80 ? 8'd127 : 8'd0-y) : y;
 // Stage 2
 reg v2=0,c2=0,sx2=0,sy2=0,xge2=0; reg [5:0] thr2=0;
 reg [8:0] radius2=0,release2=0; reg [16:0] ratio2=0;
 reg [16:0] s25=0; reg [16:0] s78=0; reg [16:0] s137=0; reg [16:0] s210=0; reg [16:0] s37=0; reg [16:0] s14=0; reg [16:0] s90=0; reg [16:0] s66=0; reg [16:0] s151=0; reg [16:0] s123=0; reg [16:0] s229=0; reg [16:0] s192=0;
 // Stage 3
 reg [2:0] selected; reg [4:0] quadrant_angle,target;
 always @* begin
  selected = ratio2<=s25 ? 0 : ratio2<=s78 ? 1 : ratio2<=s137 ? 2 : ratio2<=s210 ? 3 : 4;
  if(defl[c2]) begin
   case(region[c2])
    0: if(ratio2<=s37) selected=0;
    1: if(ratio2>=s14 && ratio2<=s90) selected=1;
    2: if(ratio2>=s66 && ratio2<=s151) selected=2;
    3: if(ratio2>=s123 && ratio2<=s229) selected=3;
    4: if(ratio2>=s192) selected=4;
    default: ;
   endcase
  end
  quadrant_angle=xge2 ? 8-selected : {2'd0,selected};
  if(!sx2 && sy2) target=quadrant_angle;                 // up/right
  else if(!sx2 && !sy2) target=16-quadrant_angle;        // down/right
  else if(sx2 && !sy2) target=16+quadrant_angle;         // down/left
  else target=5'd0-quadrant_angle;                       // up/left
 end
 always @(posedge clk) begin
  channel<=~channel;
  upd<=0;
  v1<=1; c1<=channel; sx1<=x[7]; sy1<=y[7]; xge1<=(ax>=ay);
  major1<=ax>=ay ? ax:ay; minor1<=ax>=ay ? ay:ax; thr1<=thr[channel*6+:6];
  v2<=v1; c2<=c1; sx2<=sx1; sy2<=sy1; xge2<=xge1; thr2<=thr1;
  radius2<={1'b0,major1}+({1'b0,minor1}>>1);
  release2<={3'd0,thr1}-({3'd0,thr1}>>2);
  ratio2<={1'b0,minor1,8'd0};
  s25<=scale(major1,8'd25);
  s78<=scale(major1,8'd78);
  s137<=scale(major1,8'd137);
  s210<=scale(major1,8'd210);
  s37<=scale(major1,8'd37);
  s14<=scale(major1,8'd14);
  s90<=scale(major1,8'd90);
  s66<=scale(major1,8'd66);
  s151<=scale(major1,8'd151);
  s123<=scale(major1,8'd123);
  s229<=scale(major1,8'd229);
  s192<=scale(major1,8'd192);
  if(reset) begin
   channel<=0; v1<=0; v2<=0; defl<=0; dir<=0;
   for(i=0;i<2;i=i+1) region[i]<=0;
  end else if(v2) begin
   if(radius2 >= (defl[c2] ? release2 : {3'd0,thr2})) begin
    defl[c2]<=1;
    dir[c2*5+:5]<=target;
    region[c2]<=selected;
    upd[c2]<=1;
   end else defl[c2]<=0;
  end
 end
endmodule
