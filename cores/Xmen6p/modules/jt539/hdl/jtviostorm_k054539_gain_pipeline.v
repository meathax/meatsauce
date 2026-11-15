// SPDX-License-Identifier: GPL-2.0-only
// K054539 staged six-output functional gain contract.
// Public source: furrtek/SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0,
// Konami/054539/hdl/054539.v:185-215, 849-976, 1739-1848; PDF sheet41.
// Each MULB retains bits31:16; ACCE uses arithmetic half plus product bit0.
// The high-pan path preserves registered low-pan presets from MUXC_PRE_B/A.
// Association with D/B,C/A,E/F and synchronized retirement is an explicit
// functional reconciliation of the public generated-clock ordering, not a
// certified per-edge replay or PCB claim. See gain_pipeline_contract.md.
module jtviostorm_k054539_gain_pipeline (
    input clk,
    input reset,
    input cen,
    input start,
    input signed [15:0] sample,
    input signed [15:0] volume_coefficient,
    input signed [15:0] global_coefficient,
    input signed [15:0] main_left_coefficient,
    input signed [15:0] main_right_coefficient,
    input signed [15:0] effect_left_coefficient,
    input signed [15:0] effect_right_coefficient,
    input signed [15:0] effect_a_coefficient,
    input signed [15:0] effect_b_coefficient,
    output ready,
    output reg busy,
    output reg done,
    output reg signed [15:0] after_volume,
    output reg signed [15:0] after_global,
    output reg signed [15:0] preset_left,
    output reg signed [15:0] preset_right,
    output reg signed [15:0] dry_left,
    output reg signed [15:0] dry_right,
    output reg signed [15:0] wet_left,
    output reg signed [15:0] wet_right,
    output reg signed [15:0] send_a,
    output reg signed [15:0] send_b
);
reg [1:0] phase;
reg signed [15:0] captured_sample;
reg signed [15:0] c_volume,c_global,c_main_left,c_main_right;
reg signed [15:0] c_effect_left,c_effect_right,c_effect_a,c_effect_b;
reg signed [15:0] pending_a,pending_b;

assign ready = !busy;

function signed [15:0] multiply;
    input signed [15:0] a,b;
    reg signed [31:0] product;
    begin
        product = a*b;
        multiply = product[31:16];
    end
endfunction

function signed [15:0] rounded_half;
    input signed [15:0] value;
    begin
        rounded_half = {value[15],value[15:1]} + {15'd0,value[0]};
    end
endfunction

always @(posedge clk) begin
    // The valid indication is a host-clock pulse, including between cen ticks.
    done <= 1'b0;
    if(reset) begin
        busy <= 1'b0;
        phase <= 2'd0;
        captured_sample <= 16'd0;
        c_volume <= 16'd0;
        c_global <= 16'd0;
        c_main_left <= 16'd0;
        c_main_right <= 16'd0;
        c_effect_left <= 16'd0;
        c_effect_right <= 16'd0;
        c_effect_a <= 16'd0;
        c_effect_b <= 16'd0;
        pending_a <= 16'd0;
        pending_b <= 16'd0;
        after_volume <= 16'd0;
        after_global <= 16'd0;
        preset_left <= 16'd0;
        preset_right <= 16'd0;
        dry_left <= 16'd0;
        dry_right <= 16'd0;
        wet_left <= 16'd0;
        wet_right <= 16'd0;
        send_a <= 16'd0;
        send_b <= 16'd0;
    end else if(cen) begin
        if(start && ready) begin
            captured_sample <= sample;
            c_volume <= volume_coefficient;
            c_global <= global_coefficient;
            c_main_left <= main_left_coefficient;
            c_main_right <= main_right_coefficient;
            c_effect_left <= effect_left_coefficient;
            c_effect_right <= effect_right_coefficient;
            c_effect_a <= effect_a_coefficient;
            c_effect_b <= effect_b_coefficient;
            phase <= 2'd0;
            busy <= 1'b1;
        end else if(busy) begin
            case(phase)
                2'd0: begin
                    after_volume <= multiply(captured_sample,c_volume);
                    phase <= 2'd1;
                end
                2'd1: begin
                    after_global <= multiply(after_volume,c_global);
                    phase <= 2'd2;
                end
                2'd2: begin
                    // Preserve the two main-pan products before high pan.
                    preset_left <= multiply(after_global,c_main_left);
                    preset_right <= multiply(after_global,c_main_right);
                    // Sends use volume, independently of global and both pans.
                    pending_a <= multiply(after_volume,c_effect_a);
                    pending_b <= multiply(after_volume,c_effect_b);
                    phase <= 2'd3;
                end
                2'd3: begin
                    dry_left <= rounded_half(preset_left);
                    dry_right <= rounded_half(preset_right);
                    wet_left <= rounded_half(multiply(preset_left,c_effect_left));
                    wet_right <= rounded_half(multiply(preset_right,c_effect_right));
                    send_a <= rounded_half(pending_a);
                    send_b <= rounded_half(pending_b);
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            endcase
        end
    end
end
endmodule
