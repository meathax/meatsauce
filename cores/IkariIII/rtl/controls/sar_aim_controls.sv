// SPDX-License-Identifier: GPL-3.0-or-later
module relative8_aim_controls #(parameter integer CLOCK_HZ=72000000)(
    input wire clk, reset, paused, enabled,
    input wire portrait,
    input wire [1:0] legacy_mode,
    input wire [11:0] legacy0,legacy1,
    input wire [15:0] left0, right0, left1, right1,
    input wire [1:0] speed, deadzone,
    input wire autofire, manual_fast,
    input wire [1:0] manual_left, manual_right,
    input wire [1:0] actual_strobe,
    input wire [2:0] actual0, actual1,
    output wire [3:0] move0, move1,
    output wire [11:0] rotary0, rotary1,
    output wire fire0, fire1
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
        .clk(clk),.reset(reset),.ana({right1,left1,right0,left0}),
        .thr({threshold,6'd25,threshold,6'd25}),.inv_y(4'd0),
        .defl(defl),.dir(dir),.upd(upd));

    function [3:0] compass(input [2:0] angle);
        case(angle)
            0:compass=4'b1000;
            1:compass=4'b1001;
            2:compass=4'b0001;
            3:compass=4'b0101;
            4:compass=4'b0100;
            5:compass=4'b0110;
            6:compass=4'b0010;
            7:compass=4'b1010;
        endcase
    endfunction
    assign move0=enabled && !paused && defl[0] ? compass(dir[2:0]) : 4'd0;
    assign move1=enabled && !paused && defl[2] ? compass(dir[8:6]) : 4'd0;

    wire [7:0] code0,code1;
    reg [3:0] base0=0,base1=0;
    reg [5:0] settle0=0,settle1=0;
    wire [1:0] player_enabled={enabled && !legacy_mode[1] && settle1==0,enabled && !legacy_mode[0] && settle0==0};
    reg [1:0] left_last=0,right_last=0;
    reg [1:0] step_left=0,step_right=0;
    reg [7:0] repeat_ms[0:1];
    wire [7:0] repeat_reload=manual_fast ? 8'd85 : 8'd170;
    integer i;
    always @(posedge clk) begin
        step_left<=0;step_right<=0;
        if(reset || !enabled)begin
            left_last<=0;right_last<=0;
            repeat_ms[0]<=0;repeat_ms[1]<=0;
        end else if(!paused)begin
            left_last<=manual_left;right_last<=manual_right;
            for(i=0;i<2;i=i+1)begin
                if(!player_enabled[i])begin repeat_ms[i]<=0;left_last[i]<=0;right_last[i]<=0;end
                else if(!(manual_left[i] || manual_right[i])) repeat_ms[i]<=0;
                else if((manual_left[i]!=left_last[i]) || (manual_right[i]!=right_last[i]))begin
                    step_left[i]<=manual_left[i];step_right[i]<=manual_right[i];
                    repeat_ms[i]<=repeat_reload;
                end else if(tick_ms)begin
                    if(repeat_ms[i]==0)begin
                        step_left[i]<=manual_left[i];step_right[i]<=manual_right[i];
                        repeat_ms[i]<=repeat_reload;
                    end else repeat_ms[i]<=repeat_ms[i]-8'd1;
                end
            end
        end
    end

    function [3:0] decode_legacy(input [11:0] raw);
        integer k;
        begin decode_legacy=12;for(k=0;k<12;k=k+1)if(raw==(12'b1<<k))decode_legacy=k>=4?k-4:k+8;end
    endfunction
    wire [3:0] legacy_pos0=decode_legacy(legacy0),legacy_pos1=decode_legacy(legacy1);
    always @(posedge clk)begin
        if(reset)begin base0<=0;base1<=0;settle0<=0;settle1<=0;end
        else begin
            if(legacy_mode[0])begin
                if(legacy_pos0<12)base0<=legacy_pos0>=code0 ? legacy_pos0-code0 : legacy_pos0+12-code0;
                settle0<=40;
            end else if(!paused && tick_ms && settle0!=0)settle0<=settle0-1'b1;
            if(legacy_mode[1])begin
                if(legacy_pos1<12)base1<=legacy_pos1>=code1 ? legacy_pos1-code1 : legacy_pos1+12-code1;
                settle1<=40;
            end else if(!paused && tick_ms && settle1!=0)settle1<=settle1-1'b1;
        end
    end
    // User-reported on VERT: stick direction maps to aim direction with no
    // offset. The former add6 for portrait sent left->down, down->right, etc.
    // SearchAndRescue ties portrait low for this reason.
    // Mirror horizontal aim while keeping north and south unchanged.
    wire [2:0] target0=(3'd0-dir[5:3])+(portrait ? 3'd6 : 3'd0);
    wire [2:0] target1=(3'd0-dir[11:9])+(portrait ? 3'd6 : 3'd0);
    rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(1)) p1(
        .clk(clk),.reset(reset),.paused(paused),.enable(player_enabled[0]),.tick_ms(tick_ms),
        .stick_active(defl[1]),.target_update(upd[1]),.target_angle({5'd0,target0}),
        .speed(speed),.actual_strobe(actual_strobe[0]),.actual_angle({5'd0,actual0}),
        .manual_cw(step_right[0]),.manual_ccw(step_left[0]),.code(code0),
        .target(),.observed(),.aiming(),.pending());
    rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(1)) p2(
        .clk(clk),.reset(reset),.paused(paused),.enable(player_enabled[1]),.tick_ms(tick_ms),
        .stick_active(defl[3]),.target_update(upd[3]),.target_angle({5'd0,target1}),
        .speed(speed),.actual_strobe(actual_strobe[1]),.actual_angle({5'd0,actual1}),
        .manual_cw(step_right[1]),.manual_ccw(step_left[1]),.code(code1),
        .target(),.observed(),.aiming(),.pending());
    // Raw bits11:4 carry native positions0..7, bits3:0 positions8..11.
    wire [4:0] sum0={1'b0,base0}+code0,sum1={1'b0,base1}+code1;
    wire [3:0] output_pos0=sum0>=12 ? sum0-12 : sum0;
    wire [3:0] output_pos1=sum1>=12 ? sum1-12 : sum1;
    assign rotary0=legacy_mode[0] ? legacy0 : 12'b1<<(output_pos0<8 ? output_pos0+4 : output_pos0-8);
    assign rotary1=legacy_mode[1] ? legacy1 : 12'b1<<(output_pos1<8 ? output_pos1+4 : output_pos1-8);
    aim_autofire af0(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(player_enabled[0]&&autofire),.stick_active(defl[1]),.fire(fire0));
    aim_autofire af1(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(player_enabled[1]&&autofire),.stick_active(defl[3]),.fire(fire1));
endmodule
