// SPDX-License-Identifier: GPL-3.0-or-later
module pwb_inputs(input wire clk,reset,profile,two_player,cocktail,input wire [31:0] joystick_0,joystick_1,joystick_2,joystick_3,
input wire [10:0] ps2_key,input wire [127:0] status,input wire osd_open,
output wire [7:0] system_in,p1_in,p2_in,p3_in,p4_in,dip1,dip2,dip3,output wire paused);
reg key_strobe=0;reg [9:0] keys=0;reg manual_pause=0,old_pause=0;
wire pause_button=joystick_0[9]|joystick_1[9]|joystick_2[9]|joystick_3[9]|keys[9];
always @(posedge clk) begin
 if(reset) begin key_strobe<=ps2_key[10];keys<=0;manual_pause<=0;old_pause<=0;end
 else begin
 key_strobe<=ps2_key[10];old_pause<=pause_button;
 if(pause_button&&!old_pause) manual_pause<=!manual_pause;
 if(key_strobe!=ps2_key[10]) case(ps2_key[7:0])
 8'h6b:keys[0]<=ps2_key[9];8'h74:keys[1]<=ps2_key[9];8'h75:keys[2]<=ps2_key[9];8'h72:keys[3]<=ps2_key[9];
 8'h14:keys[4]<=ps2_key[9];8'h11:keys[5]<=ps2_key[9];8'h16:keys[6]<=ps2_key[9];8'h2e:keys[7]<=ps2_key[9];8'h05:keys[8]<=ps2_key[9];8'h4d:keys[9]<=ps2_key[9];
 default:begin end endcase
 end
end
wire [31:0] j0=joystick_0|{22'd0,keys};
function automatic [7:0] player(input [31:0] j,input start_enable,input third_enable);
 player=~{(start_enable&&j[6]),(third_enable&&j[10]),j[5],j[4],j[2],j[3],j[0],j[1]};
endfunction
assign p1_in=player(j0,!profile||two_player,profile&&two_player);assign p2_in=player(joystick_1,!profile||two_player,profile&&two_player);
assign p3_in=(profile&&!two_player)?player(joystick_2,1'b0,1'b0):8'hff;assign p4_in=(profile&&!two_player)?player(joystick_3,1'b0,1'b0):8'hff;
assign system_in=~{(profile&&!two_player&&joystick_3[8]),(profile&&!two_player&&joystick_2[8]),(profile&&joystick_1[8]),j0[8],(profile&&!two_player&&joystick_3[7]),(profile&&!two_player&&joystick_2[7]),joystick_1[7],j0[7]};
// Main Event four-player marks SW1:5-8 unused. hps_io status can retain a
// Coin B selection from another MRA, so hold that unused physical nibble high.
wire [3:0] coin_b_raw=(profile&&!two_player)?4'h0:status[71:68];
assign dip1={coin_b_raw,status[67:64]}^8'hff;
assign dip2=status[79:72]^(profile?8'h57:(cocktail?8'h52:8'h56));
assign dip3=status[87:80]^8'hff;
assign paused=manual_pause||(osd_open&&!status[1]);
endmodule
