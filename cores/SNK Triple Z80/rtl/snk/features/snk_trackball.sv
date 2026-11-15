// SPDX-License-Identifier: GPL-3.0-or-later
// Country Club only: mouse P1, independent proportional left sticks and D-pads.
// X is reversed by the PCB input contract; PS/2 Y is up-positive.
module snk_trackball #(parameter integer CLK_HZ=96000000, PAD_SPEED=6)(
 input wire clk,reset,pause,
 input wire [24:0] ps2_mouse,
 input wire [31:0] joy0,joy1,
 input wire [15:0] analog0,analog1,
 input wire [1:0] speed,
 output wire [27:0] counters
);
 reg [6:0] x1=0,y1=0,x2=0,y2=0;
 reg mouse_toggle=0;
 reg [$clog2(CLK_HZ/60+1)-1:0] frame_div=0;
 wire frame_tick=frame_div==CLK_HZ/60-1;
 wire mouse_event=ps2_mouse[24]!=mouse_toggle;
 // Direct signed thresholds avoid serial absolute-value, subtraction and
 // increment carry chains on the analogue-input-to-counter timing path.
 function automatic outside_deadzone(input signed [7:0] v);
  outside_deadzone=(v > 8'sd24 || v < -8'sd24);
 endfunction
 function automatic [6:0] stick_amount(input signed [7:0] v);
  begin
   if(v >= 8'sd121 || v <= -8'sd121) stick_amount=7;
   else if(v >= 8'sd105 || v <= -8'sd105) stick_amount=6;
   else if(v >= 8'sd89 || v <= -8'sd89) stick_amount=5;
   else if(v >= 8'sd73 || v <= -8'sd73) stick_amount=4;
   else if(v >= 8'sd57 || v <= -8'sd57) stick_amount=3;
   else if(v >= 8'sd41 || v <= -8'sd41) stick_amount=2;
   else if(outside_deadzone(v)) stick_amount=1;
   else stick_amount=0;
  end
 endfunction
 function automatic signed [7:0] velocity(input [7:0] v,input minus,plus,input stick);
  reg [6:0] amount; reg neg;
  begin
   neg=v[7];amount=0;
   if(stick)amount=stick_amount(v);
   else if(minus!=plus)begin amount=PAD_SPEED;neg=minus;end
   case(speed)
    1:if(amount>1)amount=amount>>1;
    2:amount=amount<<1;
    3:amount=amount+(amount<<1);
    default:begin end
   endcase
   velocity=neg ? -$signed({1'b0,amount}) : $signed({1'b0,amount});
  end
 endfunction
 wire stick0=outside_deadzone(analog0[7:0])||outside_deadzone(analog0[15:8]);
 wire stick1=outside_deadzone(analog1[7:0])||outside_deadzone(analog1[15:8]);
 wire signed [7:0] vx0=velocity(analog0[7:0],joy0[1],joy0[0],stick0);
 wire signed [7:0] vy0=velocity(analog0[15:8],joy0[3],joy0[2],stick0);
 wire signed [7:0] vx1=velocity(analog1[7:0],joy1[1],joy1[0],stick1);
 wire signed [7:0] vy1=velocity(analog1[15:8],joy1[3],joy1[2],stick1);
 always @(posedge clk)begin
  mouse_toggle<=ps2_mouse[24];
  if(reset)begin x1<=0;y1<=0;x2<=0;y2<=0;frame_div<=0;end
  else if(pause)frame_div<=0;
  else begin
   frame_div<=frame_tick?0:frame_div+1'b1;
   // Sum simultaneous mouse and controller updates; neither player loses a tick.
   x1<=x1-(mouse_event?ps2_mouse[14:8]:7'd0)-(frame_tick?vx0[6:0]:7'd0);
   y1<=y1-(mouse_event?ps2_mouse[22:16]:7'd0)+(frame_tick?vy0[6:0]:7'd0);
   if(frame_tick)begin x2<=x2-vx1[6:0];y2<=y2+vy1[6:0];end
  end
 end
 assign counters={y2,x2,y1,x1};
endmodule
