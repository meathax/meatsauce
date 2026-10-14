// SPDX-License-Identifier: GPL-2.0-or-later
// Sheriff IN0/IN1: R,L,U,D movement then R,L,U,D independent aiming.
// Port definition: MAME 0.289 src/mame/nintendo/n8080.cpp.
module n8080_controls (
    input wire clk, reset,
    input wire [31:0] joy0, joy1,
    input wire [15:0] analog_l0, analog_l1, analog_r0, analog_r1,
    input wire [10:0] ps2_key,
    input wire rotate_aim,
    output wire [7:0] input0, input1, input2,
    output reg paused=0
);
    reg [3:0] key_move0=0,key_move1=0,key_aim0=0,key_aim1=0;
    reg key_fire0=0,key_fire1=0,key_start1=0,key_start2=0,key_coin=0,key_pause=0;
    reg previous_key=0,previous_pause=0;
    reg [1:0] previous_rotate0=0,previous_rotate1=0;
    reg [2:0] angle0=2,angle1=2;
    function automatic [3:0] analog_direction(input [15:0] axes);
        reg signed [7:0] x,y;
        begin
            x=$signed(axes[7:0]);y=$signed(axes[15:8]);
            analog_direction={y>8'sd32,y < -8'sd32,x < -8'sd32,x>8'sd32};
        end
    endfunction
    function automatic [3:0] legal_direction(input [3:0] raw);
        begin legal_direction={raw[3]&!raw[2],raw[2]&!raw[3],raw[1]&!raw[0],raw[0]&!raw[1]};end
    endfunction
    function automatic [3:0] rotary(input [2:0] angle);
        begin case(angle)
            0:rotary=4'h4;1:rotary=4'h5;2:rotary=4'h1;3:rotary=4'h9;
            4:rotary=4'h8;5:rotary=4'ha;6:rotary=4'h2;7:rotary=4'h6;
        endcase end
    endfunction
    // MiSTer joystick bits are R,L,D,U; Sheriff port bits are R,L,U,D.
    wire [3:0] digital_move0={joy0[2],joy0[3],joy0[1:0]};
    wire [3:0] digital_move1={joy1[2],joy1[3],joy1[1:0]};
    wire [3:0] move0=legal_direction(digital_move0|analog_direction(analog_l0)|key_move0);
    wire [3:0] move1=legal_direction(digital_move1|analog_direction(analog_l1)|key_move1);
    wire [3:0] aim0=legal_direction((rotate_aim?rotary(angle0):joy0[11:8])|analog_direction(analog_r0)|key_aim0);
    wire [3:0] aim1=legal_direction((rotate_aim?rotary(angle1):joy1[11:8])|analog_direction(analog_r1)|key_aim1);
    assign input0={aim0,move0};
    assign input1={aim1,move1};
    assign input2={joy0[7]|joy1[7]|key_coin,3'b000,
                   joy0[6]|joy1[6]|key_start2,joy0[5]|joy1[5]|key_start1,
                   joy1[4]|key_fire1,joy0[4]|key_fire0};
    always @(posedge clk) begin
        previous_key<=ps2_key[10];previous_pause<=joy0[12]|joy1[12];
        previous_rotate0<=joy0[9:8];previous_rotate1<=joy1[9:8];
        if(reset) begin
            key_move0<=0;key_move1<=0;key_aim0<=0;key_aim1<=0;
            key_fire0<=0;key_fire1<=0;key_start1<=0;key_start2<=0;key_coin<=0;key_pause<=0;
            angle0<=2;angle1<=2;paused<=0;
        end else begin
            if((joy0[12]|joy1[12])&&!previous_pause)paused<=!paused;
            if(rotate_aim) begin
                if(joy0[8]&&!previous_rotate0[0])angle0<=angle0+1'b1;
                else if(joy0[9]&&!previous_rotate0[1])angle0<=angle0-1'b1;
                if(joy1[8]&&!previous_rotate1[0])angle1<=angle1+1'b1;
                else if(joy1[9]&&!previous_rotate1[1])angle1<=angle1-1'b1;
            end
            if(ps2_key[10]!=previous_key) begin
                case(ps2_key[8:0])
                    9'h023:key_move0[0]<=ps2_key[9]; // D
                    9'h01c:key_move0[1]<=ps2_key[9]; // A
                    9'h01d:key_move0[2]<=ps2_key[9]; // W
                    9'h01b:key_move0[3]<=ps2_key[9]; // S
                    9'h04b:key_aim0[0]<=ps2_key[9]; // L
                    9'h03b:key_aim0[1]<=ps2_key[9]; // J
                    9'h043:key_aim0[2]<=ps2_key[9]; // I
                    9'h042:key_aim0[3]<=ps2_key[9]; // K
                    9'h174:key_move1[0]<=ps2_key[9]; // arrows, extended
                    9'h16b:key_move1[1]<=ps2_key[9];
                    9'h175:key_move1[2]<=ps2_key[9];
                    9'h172:key_move1[3]<=ps2_key[9];
                    9'h074:key_aim1[0]<=ps2_key[9]; // keypad 6/4/8/2
                    9'h06b:key_aim1[1]<=ps2_key[9];
                    9'h075:key_aim1[2]<=ps2_key[9];
                    9'h072:key_aim1[3]<=ps2_key[9];
                    9'h029:key_fire0<=ps2_key[9]; // Space
                    9'h05a:key_fire1<=ps2_key[9]; // Enter
                    9'h016:key_start1<=ps2_key[9]; // 1
                    9'h01e:key_start2<=ps2_key[9]; // 2
                    9'h02e:key_coin<=ps2_key[9]; // 5
                    9'h04d:begin // P; suppress keyboard autorepeat
                        key_pause<=ps2_key[9];
                        if(ps2_key[9]&&!key_pause)paused<=!paused;
                    end
                    default:begin end
                endcase
            end
        end
    end
endmodule
