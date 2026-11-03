// SPDX-License-Identifier: GPL-3.0-or-later
// SNK donor conventions: four interleaved signed {Y,X} channels, Y down,
// octagonal radial deadzone, 75% radial release and retained centred target.
// Sixteen clockwise sectors: 0=N,4=E,8=S,12=W. Integer ratio boundaries
// approximate tan(11.25deg) and tan(33.75deg) within 0.05 degrees.
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
 reg [7:0] x,y,ax,ay,major,minor;
 reg [5:0] threshold;
 reg [8:0] radius,release_threshold;
 reg [16:0] ratio;
 reg [1:0] selected;
 reg [3:0] quadrant_angle,target;
 integer i;
 // Fixed coefficients synthesize to shifts/adds, with no variable divider.
 function automatic [16:0] scale(input [7:0] value,input [7:0] coefficient);
  integer bitno;
  begin
   scale=0;
   for(bitno=0;bitno<8;bitno=bitno+1)
    if(coefficient[bitno]) scale=scale+({9'd0,value}<<bitno);
  end
 endfunction
 always @* begin
  x=ana[channel*16+:8]; y=ana[channel*16+8+:8];
  threshold=thr[channel*6+:6];
  ax=x[7] ? (x==8'h80 ? 8'd127 : 8'd0-x) : x;
  ay=y[7] ? (y==8'h80 ? 8'd127 : 8'd0-y) : y;
  major=ax>=ay ? ax:ay; minor=ax>=ay ? ay:ax;
  radius={1'b0,major}+({1'b0,minor}>>1);
  release_threshold={3'd0,threshold}-({3'd0,threshold}>>2);
  ratio={1'b0,minor,8'd0};
  // Initial classification uses nominal boundaries; a held sector uses
  // ~2.5-degree hysteresis on either side of its nearest boundary.
  selected=ratio<=scale(major,8'd51) ? 0 : ratio<=scale(major,8'd171) ? 1:2;
  if(defl[channel]) begin
   case(region[channel])
    0: if(ratio<=scale(major,8'd63)) selected=0;
    1: begin
     if(ratio>=scale(major,8'd39) && ratio<=scale(major,8'd188)) selected=1;
    end
    2: if(ratio>=scale(major,8'd155)) selected=2;
   endcase
  end
  quadrant_angle=ax>=ay ? 4-selected : selected;
  if(!x[7] && y[7]) target=quadrant_angle;
  else if(!x[7] && !y[7]) target=8-quadrant_angle;
  else if(x[7] && !y[7]) target=8+quadrant_angle;
  else target=0-quadrant_angle;
 end
 always @(posedge clk) begin
  channel<=channel+1'b1;
  upd<=0;
  if(reset) begin
   channel<=0;defl<=0;dir<=0;
   for(i=0;i<4;i=i+1) region[i]<=0;
  end else if(radius >= (defl[channel] ? release_threshold : {3'd0,threshold})) begin
   defl[channel]<=1;
   dir[channel*4+:4]<=target;
   region[channel]<=selected;
   upd[channel]<=1;
  end else defl[channel]<=0;
 end
endmodule
