// SPDX-License-Identifier: GPL-3.0-or-later
// Left analogue stick -> active-high digital directions {up,down,left,right}
// (JTFRAME joystick bit order 0=right,1=left,2=down,3=up). Signed bytes
// {Y,X}, Y down. Per-axis threshold with 75% release.
module analog_move8(
 input wire clk, reset,
 input wire [15:0] ana,
 input wire [5:0] threshold,
 output reg [3:0] move = 0
);
 wire signed [7:0] x=ana[7:0], y=ana[15:8];
 wire [7:0] ax=x[7] ? (x==8'h80 ? 8'd127 : 8'd0-x) : x;
 wire [7:0] ay=y[7] ? (y==8'h80 ? 8'd127 : 8'd0-y) : y;
 wire [7:0] t_on={2'd0,threshold};
 wire [7:0] t_off={2'd0,threshold}-({2'd0,threshold}>>2);
 wire x_on=ax>=(move[0]|move[1] ? t_off : t_on);
 wire y_on=ay>=(move[2]|move[3] ? t_off : t_on);
 always @(posedge clk) begin
  if(reset) move<=0;
  else move<={y_on && y[7], y_on && !y[7], x_on && x[7], x_on && !x[7]};
 end
endmodule
