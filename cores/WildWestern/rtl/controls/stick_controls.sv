// SPDX-License-Identifier: GPL-3.0-or-later
// Screen compass N,NE,E,SE,S,SW,W,NW. MiSTer signed {Y,X}, Y down.
module stick_controls #(parameter integer CLK_HZ=48000000, parameter RELATIVE=0)(
 input wire clk,reset,paused, input wire [15:0] left,right,
 input wire [1:0] speed,deadzone,input wire autofire,
 output wire [3:0] move,output reg [2:0] direction=0,
 output wire [3:0] aim,output wire fire,turn_left,turn_right,output wire active);
 wire [5:0] threshold=deadzone==1?6'd13:deadzone==2?6'd38:deadzone==3?6'd51:6'd32;
 wire [3:0] defl,upd;wire [11:0] dirs;
 snk_aim_quant4 q(.clk(clk),.reset(reset),.ana({32'd0,right,left}),.thr({4{threshold}}),.inv_y(4'd0),.defl(defl),.dir(dirs),.upd(upd));
 analog_move8 m(.clk(clk),.reset(reset),.ana(left),.threshold(threshold),.move(move));
 reg [31:0] timer=0,ft=0;reg [2:0] pending=0;
 wire [31:0] delay_cycles=speed==1?CLK_HZ/25:speed==2?0:CLK_HZ*12/1000;
 wire [31:0] turn_period=speed==1?CLK_HZ/4:speed==2?CLK_HZ/32:CLK_HZ/8;
 wire signed [7:0] x=right[7:0];
 assign active=RELATIVE ? ((x>$signed({2'b0,threshold})) || (x<-$signed({2'b0,threshold}))) : defl[1];
 assign turn_left=RELATIVE && active && x[7] && timer<turn_period/2 && !paused;
 assign turn_right=RELATIVE && active && !x[7] && timer<turn_period/2 && !paused;
 assign fire=autofire && active && !paused && ft<CLK_HZ/40;
 assign aim=!(RELATIVE==2 || defl[1]) ? 4'd0 : direction==0?4'b1000:direction==1?4'b1001:direction==2?4'b0001:direction==3?4'b0101:direction==4?4'b0100:direction==5?4'b0110:direction==6?4'b0010:4'b1010;
 always @(posedge clk) begin
  if(reset)begin timer<=0;ft<=0;direction<=0;pending<=0;end
  else if(!paused) begin
   ft<=!active || ft>=CLK_HZ/10-1 ? 0:ft+1'b1;
   if(RELATIVE) begin
    timer<=!active || timer>=turn_period-1?0:timer+1'b1;
    if(RELATIVE==2 && active && timer==0) direction<=x[7] ? direction-3'd1 : direction+3'd1;
   end
   else if(defl[1]) begin
    if(pending!=dirs[5:3])begin pending<=dirs[5:3];timer<=0;end
    else if(timer>=delay_cycles) begin
     if(speed==2) direction<=pending;
     else if(direction!=pending) direction<=((pending-direction)&3'd7)<=3'd4 ? direction+3'd1:direction-3'd1;
     timer<=0;
    end
    else timer<=timer+1'b1;
   end else timer<=0;
  end
 end
endmodule
