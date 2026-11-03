// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer J1 ordering and set-2 keyboard events, all in clk_sys.
module thunderjaws_controls(
 input wire clk_sys,init_reset,service_menu,
 input wire [31:0] joystick_0,joystick_1,
 input wire [10:0] ps2_key,
 output wire [3:0] p1_directions,p2_directions,
 output wire [1:0] p1_buttons,p2_buttons,
 output wire [2:0] coin,
 output wire service_test,
 output reg pause_request
);
 reg old_key,old_pause,old_service,service_toggle;
 reg [3:0] keys1,keys2;
 reg fire1,jump1,start1,coin1,fire2,jump2,start2,coin2,service_coin;
 reg pause_down,service_down;
 wire joy_pause=joystick_0[8] || joystick_1[8];
 wire joy_service=joystick_0[9] || joystick_1[9];
 assign p1_directions=joystick_0[3:0] | keys1;
 assign p2_directions=joystick_1[3:0] | keys2;
 assign p1_buttons={joystick_0[5] || jump1,joystick_0[4] || joystick_0[6] || fire1 || start1};
 assign p2_buttons={joystick_1[5] || jump2,joystick_1[4] || joystick_1[6] || fire2 || start2};
 assign coin={service_coin,joystick_1[7] || coin2,joystick_0[7] || coin1};
 assign service_test=service_menu || service_toggle;
 always @(posedge clk_sys)begin
  if(init_reset)begin
   old_key<=ps2_key[10];old_pause<=0;old_service<=0;service_toggle<=0;pause_request<=0;
   keys1<=0;keys2<=0;fire1<=0;jump1<=0;start1<=0;coin1<=0;
   fire2<=0;jump2<=0;start2<=0;coin2<=0;service_coin<=0;pause_down<=0;service_down<=0;
  end else begin
   old_key<=ps2_key[10];old_pause<=joy_pause;old_service<=joy_service;
   if(joy_pause && !old_pause)pause_request<=!pause_request;
   if(joy_service && !old_service)service_toggle<=!service_toggle;
   if(old_key!=ps2_key[10])case({ps2_key[8],ps2_key[7:0]})
    9'h174:keys1[0]<=ps2_key[9];9'h16b:keys1[1]<=ps2_key[9];
    9'h172:keys1[2]<=ps2_key[9];9'h175:keys1[3]<=ps2_key[9];
    9'h014:fire1<=ps2_key[9];9'h011:jump1<=ps2_key[9];
    9'h016:start1<=ps2_key[9];9'h02e:coin1<=ps2_key[9];
    9'h023:keys2[0]<=ps2_key[9];9'h01c:keys2[1]<=ps2_key[9];
    9'h01b:keys2[2]<=ps2_key[9];9'h01d:keys2[3]<=ps2_key[9];
    9'h114:fire2<=ps2_key[9];9'h111:jump2<=ps2_key[9];
    9'h01e:start2<=ps2_key[9];9'h036:coin2<=ps2_key[9];
    9'h046:service_coin<=ps2_key[9];
    9'h04d:begin
     pause_down<=ps2_key[9];
     if(ps2_key[9] && !pause_down)pause_request<=!pause_request;
    end
    9'h006:begin
     service_down<=ps2_key[9];
     if(ps2_key[9] && !service_down)service_toggle<=!service_toggle;
    end
    default:;
   endcase
  end
 end
endmodule
