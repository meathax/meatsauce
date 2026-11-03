// SPDX-License-Identifier: GPL-3.0-or-later
// Midnight Resistance twin-stick additions (DEC1 12-contact rotary, MAME 0.289 midres).
// Native contract (see docs/MIDRES_AIM_CONTRACT.md): the game reads the active-low
// one-hot contact at 180004/180006 and integrates it as a RELATIVE input into its own
// eight-state aim byte (P1 1021BC, P2 102238; value = 4*state, 0=N 1=NE ... 7=NW).
// +1 contact position (one-hot shifts left) lowers the game angle by one state (CCW).
// This block walks the contact one legal step at a time until the game's own angle,
// observed from completed CPU writes, matches the quantized right stick.
module midres_aim_controls #(parameter integer CLOCK_HZ=48000000)(
    input wire clk, reset, paused,
    input wire [15:0] left1, left2, right1, right2,
    input wire [1:0] speed, deadzone,
    input wire autofire,
    input wire [1:0] actual_strobe,
    input wire [2:0] actual1, actual2,
    input wire [1:0] manual_cw, manual_ccw,
    input wire [11:0] legacy1, legacy2,
    output wire [11:0] rotary1, rotary2,
    output wire [3:0] move1, move2,     // {right,left,down,up}, 1 = pressed
    output wire [1:0] fire,
    output wire [1:0] owned
);
    localparam integer MS_DIV=CLOCK_HZ/1000;
    localparam integer MS_W=MS_DIV<2 ? 1 : $clog2(MS_DIV);
    reg [MS_W-1:0] ms_count=0;
    wire tick_ms=ms_count==MS_DIV-1;
    always @(posedge clk) begin
        if(reset || tick_ms) ms_count<=0;
        else ms_count<=ms_count+1'b1;
    end

    wire [5:0] threshold=deadzone==0 ? 6'd32 : deadzone==1 ? 6'd13 : deadzone==2 ? 6'd38 : 6'd51;
    wire [3:0] defl,upd;
    wire [11:0] dir;
    snk_aim_quant4 quant(
        .clk(clk),.reset(reset),.ana({right2,left2,right1,left1}),
        .thr({threshold,6'd25,threshold,6'd25}),.inv_y(4'd0),
        .defl(defl),.dir(dir),.upd(upd));

    function [3:0] compass(input [2:0] angle);
        case(angle)
            0:compass=4'b0001;
            1:compass=4'b1001;
            2:compass=4'b1000;
            3:compass=4'b1010;
            4:compass=4'b0010;
            5:compass=4'b0110;
            6:compass=4'b0100;
            default:compass=4'b0101;
        endcase
    endfunction
    assign move1=!paused && defl[0] ? compass(dir[2:0]) : 4'd0;
    assign move2=!paused && defl[2] ? compass(dir[8:6]) : 4'd0;

    // Ownership starts at the first right-stick deflection of that player; until then
    // the original rotary registers are passed through untouched.
    reg [1:0] owns=0;
    always @(posedge clk) begin
        if(reset) owns<=0;
        else begin
            if(defl[1]) owns[0]<=1;
            if(defl[3]) owns[1]<=1;
        end
    end
    assign owned=owns;

    function [3:0] decode_pos(input [11:0] raw);
        integer k;
        begin decode_pos=12;for(k=0;k<12;k=k+1)if(raw==(12'b1<<k))decode_pos=k;end
    endfunction
    wire [3:0] legacy_pos1=decode_pos(legacy1),legacy_pos2=decode_pos(legacy2);
    wire [7:0] code1,code2;
    reg [3:0] base1=0,base2=0;
    always @(posedge clk) begin
        if(reset) begin base1<=0;base2<=0;end
        else begin
            // Track the original rotary until taken over, so the output is continuous.
            if(!owns[0] && legacy_pos1<12) base1<=legacy_pos1;
            if(!owns[1] && legacy_pos2<12) base2<=legacy_pos2;
        end
    end

    wire [2:0] target1=dir[5:3],target2=dir[11:9];
    rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) p1(
        .clk(clk),.reset(reset),.paused(paused),.enable(owns[0]),.tick_ms(tick_ms),
        .stick_active(defl[1]),.target_update(upd[1]),.target_angle({5'd0,target1}),
        .speed(speed),.actual_strobe(actual_strobe[0]),.actual_angle({5'd0,actual1}),
        .manual_cw(manual_cw[0]),.manual_ccw(manual_ccw[0]),.code(code1),
        .target(),.observed(),.aiming(),.pending());
    rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) p2(
        .clk(clk),.reset(reset),.paused(paused),.enable(owns[1]),.tick_ms(tick_ms),
        .stick_active(defl[3]),.target_update(upd[3]),.target_angle({5'd0,target2}),
        .speed(speed),.actual_strobe(actual_strobe[1]),.actual_angle({5'd0,actual2}),
        .manual_cw(manual_cw[1]),.manual_ccw(manual_ccw[1]),.code(code2),
        .target(),.observed(),.aiming(),.pending());

    wire [4:0] sum1={1'b0,base1}+code1[3:0],sum2={1'b0,base2}+code2[3:0];
    wire [3:0] pos1=sum1>=12 ? sum1-5'd12 : sum1[3:0];
    wire [3:0] pos2=sum2>=12 ? sum2-5'd12 : sum2[3:0];
    assign rotary1=owns[0] ? (12'b1<<pos1) : legacy1;
    assign rotary2=owns[1] ? (12'b1<<pos2) : legacy2;

    aim_autofire af1(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(autofire),.stick_active(defl[1]),.fire(fire[0]));
    aim_autofire af2(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(autofire),.stick_active(defl[3]),.fire(fire[1]));
endmodule
