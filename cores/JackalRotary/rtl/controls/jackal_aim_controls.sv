// SPDX-License-Identifier: GPL-3.0-or-later
module jackal_aim_controls #(parameter integer CLOCK_HZ=49152000)(
    input wire clk, reset, paused, enabled,
    input wire [15:0] left0, right0, left1, right1,
    input wire [1:0] speed, deadzone,
    input wire autofire, manual_fast,
    input wire [1:0] manual_left, manual_right,
    input wire [1:0] actual_strobe,
    input wire [2:0] actual0, actual1,
    output wire [3:0] move0, move1,
    output wire [7:0] rotary0, rotary1,
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
                if(!(manual_left[i] || manual_right[i])) repeat_ms[i]<=0;
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

    wire [7:0] code0,code1;
    rotary_target_servo p1(
        .clk(clk),.reset(reset),.paused(paused),.enable(enabled),.tick_ms(tick_ms),
        .stick_active(defl[1]),.target_update(upd[1]),.target_angle({5'd0,dir[5:3]}),
        .speed(speed),.actual_strobe(actual_strobe[0]),.actual_angle({5'd0,actual0}),
        .manual_cw(step_right[0]),.manual_ccw(step_left[0]),.code(code0),
        .target(),.observed(),.aiming(),.pending());
    rotary_target_servo p2(
        .clk(clk),.reset(reset),.paused(paused),.enable(enabled),.tick_ms(tick_ms),
        .stick_active(defl[3]),.target_update(upd[3]),.target_angle({5'd0,dir[11:9]}),
        .speed(speed),.actual_strobe(actual_strobe[1]),.actual_angle({5'd0,actual1}),
        .manual_cw(step_right[1]),.manual_ccw(step_left[1]),.code(code1),
        .target(),.observed(),.aiming(),.pending());
    assign rotary0=8'b1<<code0[2:0];
    assign rotary1=8'b1<<code1[2:0];
    aim_autofire af0(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(enabled&&autofire),.stick_active(defl[1]),.fire(fire0));
    aim_autofire af1(.clk(clk),.reset(reset),.paused(paused),.tick_ms(tick_ms),
        .enable(enabled&&autofire),.stick_active(defl[3]),.fire(fire1));
endmodule

module jackal_aim_snoop(
    input wire clk, reset, cpu_write, hs_access,
    input wire [15:0] address,
    input wire [7:0] data,
    output reg [1:0] actual_strobe=0,
    output reg [2:0] actual0=0, actual1=0
);
    always @(posedge clk) begin
        actual_strobe<=0;
        if(reset)begin actual0<=0;actual1<=0;end
        else if(cpu_write && !hs_access && data[7:3]==0)begin
            if(address==16'h0be7)begin actual0<=data[2:0];actual_strobe[0]<=1;end
            if(address==16'h0c0f)begin actual1<=data[2:0];actual_strobe[1]<=1;end
        end
    end
endmodule
