// SPDX-License-Identifier: GPL-3.0-or-later
// Uses the SNK Triple Z80 controller's game-feedback/one-legal-step method.
// The wrapper supplies completed game aim writes, not the rotary input code.
module d8_aim_servo #(
    parameter integer ANGLE_STATES = 8,
    parameter integer CODE_STATES = 8,
    parameter integer CODE_POSITIVE_IS_CW = 1
)(
    input wire clk, reset, paused, enable, tick_ms,
    input wire stick_active, target_update,
    input wire [7:0] target_angle,
    // 0=Normal (40ms/acknowledged step), 1=Slow (100ms), 2=Instant.
    input wire [1:0] speed,
    input wire actual_strobe,
    input wire [7:0] actual_angle,
    input wire manual_load,
    input wire [7:0] manual_code,
    input wire manual_cw, manual_ccw,
    output reg [7:0] code = 0,
    output reg [7:0] target = 0,
    output reg aiming = 0,
    output reg pending = 0,
    output reg [7:0] observed = 0
);
    reg observed_valid = 0;
    reg suspended = 0;
    reg [7:0] acknowledged_code = 0;
    reg [7:0] expected_angle = 0;
    reg [7:0] age_ms = 0;
    reg [7:0] delay_ms = 0;
    wire [7:0] step_delay = speed == 0 ? 8'd12 : speed == 1 ? 8'd40 : 8'd0;
    wire [8:0] cw_distance = target >= observed ?
        {1'b0,target} - {1'b0,observed} :
        ANGLE_STATES + {1'b0,target} - {1'b0,observed};
    wire turn_cw = cw_distance <= ANGLE_STATES/2;

    function [7:0] advance_code(input [7:0] old_code, input clockwise);
        begin
            if(clockwise == (CODE_POSITIVE_IS_CW != 0))
                advance_code = old_code == CODE_STATES-1 ? 8'd0 : old_code + 8'd1;
            else
                advance_code = old_code == 0 ? CODE_STATES-1 : old_code - 8'd1;
        end
    endfunction

    always @(posedge clk) begin
        if(reset) begin
            code <= 0;
            target <= 0;
            observed <= 0;
            aiming <= 0;
            pending <= 0;
            observed_valid <= 0;
            suspended <= 0;
            acknowledged_code <= 0;
            expected_angle <= 0;
            age_ms <= 0;
            delay_ms <= 0;
        end else begin
            // A CPU may finish a write while its pause request drains. Consume
            // that feedback without moving the target, rotary code or timers.
            if(actual_strobe && actual_angle < ANGLE_STATES) begin
                observed <= actual_angle;
                observed_valid <= 1;
            end
            if(paused) begin
                if(pending && actual_strobe && actual_angle == expected_angle) begin
                    acknowledged_code <= code;
                    pending <= 0;
                    age_ms <= 0;
                    delay_ms <= step_delay;
                end
            end else begin
            if(tick_ms && delay_ms != 0) delay_ms <= delay_ms - 8'd1;
            if(!enable) begin
                aiming <= 0;
                pending <= 0;
                suspended <= 0;
                acknowledged_code <= code;
            end else if(manual_load) begin
                code <= manual_code;
                acknowledged_code <= manual_code;
                aiming <= 0;
                suspended <= stick_active;
                pending <= 0;
                age_ms <= 0;
                delay_ms <= 0;
            end else if(manual_cw || manual_ccw) begin
                // Manual pulses already include the wrapper's repeat pacing.
                // Suppress automatic reacquisition until the stick is centred.
                aiming <= 0;
                suspended <= 1;
                pending <= 0;
                age_ms <= 0;
                delay_ms <= 0;
                if(manual_cw != manual_ccw) begin
                    code <= advance_code(code, manual_cw);
                    acknowledged_code <= advance_code(code, manual_cw);
                end
            end else begin
                if(!stick_active) suspended <= 0;
                if(target_update && stick_active && !suspended && target_angle < ANGLE_STATES) begin
                    target <= target_angle;
                    aiming <= 1;
                end
                if(pending) begin
                    if(actual_strobe && actual_angle == expected_angle) begin
                        acknowledged_code <= code;
                        pending <= 0;
                        age_ms <= 0;
                        delay_ms <= step_delay;
                    end else if(tick_ms) begin
                        if(age_ms == 119) begin
                            // Intros/respawns may absorb the rotary sample.
                            // Bound the unacknowledged displacement to one step.
                            code <= acknowledged_code;
                            pending <= 0;
                            age_ms <= 0;
                            delay_ms <= 250;
                        end else age_ms <= age_ms + 8'd1;
                    end
                end else if(aiming && observed_valid && !actual_strobe && delay_ms == 0 && target != observed) begin
                    code <= advance_code(code, turn_cw);
                    expected_angle <= turn_cw ?
                        (observed == ANGLE_STATES-1 ? 8'd0 : observed + 8'd1) :
                        (observed == 0 ? ANGLE_STATES-1 : observed - 8'd1);
                    pending <= 1;
                    age_ms <= 0;
                end
            end
            end
        end
    end
endmodule

