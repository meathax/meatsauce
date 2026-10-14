// SPDX-License-Identifier: BSD-3-Clause
// Genuine time-multiplexable VRender0 sample-fetch / voice arithmetic pipeline.
// Matches the pinned MAME 0.289 render_audio integer behavior. Scheduling,
// channel registers, global control, mixing and IRQs belong to the SPU wrapper.
module vr0_voice (
    input logic clk, reset,
    input logic job_valid,
    output logic job_ready,
    input logic [31:0] current_address,
    input logic signed [31:0] envelope_volume,
    input logic [7:0] envelope_stage,
    input logic [15:0] frequency,
    input logic [6:0] modes,
    input logic texture_selected,
    input logic [21:0] loop_begin, loop_end,
    input logic [6:0] left_volume, right_volume,
    input logic [127:0] envelope_rates,
    input logic [27:0] envelope_targets,
    input logic [19:0] clock_divisor,
    output logic result_valid,
    input logic result_ready,
    output logic [31:0] next_address,
    output logic signed [31:0] next_envelope_volume,
    output logic [7:0] next_envelope_stage,
    output logic signed [31:0] left_contribution, right_contribution,
    output logic ended, memory_fault,
    output logic [6:0] unsupported_modes,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error
);
    import vr0_audio_pkg::*;
    typedef enum logic [3:0] {IDLE, REQUEST, RESPONSE, POSITION,
        GAIN, ENVELOPE, PAN, PAN_RESULT, RESULT} state_t;
    state_t state;
    logic [31:0] position, fetched;
    logic signed [31:0] env, scaled_sample;
    logic [7:0] stage;
    logic [15:0] pitch;
    logic [6:0] flags, lvol, rvol;
    logic [21:0] begin_address, end_address;
    logic [127:0] rates;
    logic [27:0] targets;
    logic [19:0] divisor;
    logic selected_texture;
    logic [1:0] level;
    logic [31:0] advanced_address;
    logic signed [31:0] pitch_product, gain_product, rate_product;
    logic signed [31:0] rate_delta, updated_envelope, pan_left, pan_right;
    logic signed [31:0] rate_delta_hold;
    logic [1:0] next_rate_level;
    logic signed [31:0] raw_sample;
    logic signed [15:0] decoded_sample_hold;
    logic signed [15:0] pitch_step_hold;
    logic [22:0] pan_left_low,pan_right_low;
    logic signed [15:0] pan_left_high,pan_right_high;
    logic [7:0] sample_byte;
    logic [15:0] sample_word, decoded_ulaw;
    logic [6:0] target;
    logic [7:0] shifted_stage;

    always_comb begin
        job_ready=state==IDLE;
        result_valid=state==RESULT;
        req_valid=state==REQUEST;
        req_address=(selected_texture?32'h03800000:32'h04000000)+
                    {9'b0,position[31:11],2'b00};
        req_data=0; req_strobe=4'hf; req_write=0;
        sample_byte=8'(fetched >> ({3'b0,position[10:9]}*5'd8));
        sample_word=position[10] ? fetched[31:16] : fetched[15:0];
        decoded_ulaw=ulaw_decode(sample_byte);
        if (flags[4]) raw_sample={{16{decoded_ulaw[15]}},decoded_ulaw};
        else if (flags[5]) raw_sample={{16{sample_byte[7]}},sample_byte,8'd0};
        else raw_sample={{16{sample_word[15]}},sample_word};
        // Explicit 32-bit products preserve the reference integer wrapping.
        pitch_product=$signed({16'd0,pitch})*$signed({12'd0,divisor});
        advanced_address=position+32'(pitch_step_hold);
        gain_product=decoded_sample_hold*$signed(env[31:16]);
        // GAIN prepares level zero; each envelope cycle prepares the following
        // level while applying the held delta. Separate multiply from the
        // envelope add/target compare without adding a voice pipeline cycle.
        next_rate_level=state==GAIN ? 2'd0 : level+2'd1;
        rate_product=$signed(rates[{next_rate_level,5'b00000}+:32])*$signed({12'd0,divisor});
        rate_delta=rate_delta_hold;
        updated_envelope=env+rate_delta;
        target=targets[int'(level)*7+:7];
        shifted_stage=stage<<1;
        // GAIN stores a signed 24-bit sample (32-bit product >>> 8).
        // Reconstruct the exact wrapping product from registered low/high parts.
        pan_left=$signed({pan_left_high,16'b0})+$signed({9'b0,pan_left_low});
        pan_right=$signed({pan_right_high,16'b0})+$signed({9'b0,pan_right_low});
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state<=IDLE;position<=0;fetched<=0;env<=0;stage<=0;
            pitch<=0;flags<=0;lvol<=0;rvol<=0;begin_address<=0;end_address<=0;
            rates<=0;targets<=0;divisor<=0;selected_texture<=0;level<=0;
            scaled_sample<=0;rate_delta_hold<=0;decoded_sample_hold<=0;next_address<=0;next_envelope_volume<=0;
            pitch_step_hold<=0;pan_left_low<=0;pan_right_low<=0;pan_left_high<=0;pan_right_high<=0;
            next_envelope_stage<=0;left_contribution<=0;right_contribution<=0;
            ended<=0;memory_fault<=0;unsupported_modes<=0;
        end else begin
            case (state)
                IDLE: if (job_valid) begin
                    position<=current_address;env<=envelope_volume;stage<=envelope_stage;
                    pitch<=frequency;flags<=modes;lvol<=left_volume;rvol<=right_volume;
                    begin_address<=loop_begin;end_address<=loop_end;
                    rates<=envelope_rates;targets<=envelope_targets;divisor<=clock_divisor;
                    selected_texture<=texture_selected;ended<=0;memory_fault<=0;
                    next_address<=current_address;next_envelope_volume<=envelope_volume;next_envelope_stage<=envelope_stage;
                    unsupported_modes<=modes&7'h0a; // sustain and ping-pong lack reference semantics
                    left_contribution<=0;right_contribution<=0;
                    state<=REQUEST;
                end
                REQUEST: begin
                    pitch_step_hold<=pitch_product[31:16];
                    if (req_ready) begin
                    if (rsp_valid) begin
                        fetched<=rsp_data;
                        if (rsp_error) begin memory_fault<=1;state<=RESULT;end
                        else state<=POSITION;
                    end else state<=RESPONSE;
                    end
                end
                RESPONSE: if (rsp_valid) begin
                    fetched<=rsp_data;
                    if (rsp_error) begin memory_fault<=1;state<=RESULT;end
                    else state<=POSITION;
                end
                POSITION: begin
                    // Fetched data is stable here. Decode before GAIN so the
                    // sample mux/u-law table do not precede the gain multiply.
                    decoded_sample_hold<=raw_sample[15:0];
                    if (advanced_address >= {end_address,10'd0}) begin
                        if (flags[0]) begin
                            next_address<=advanced_address-{end_address,10'd0}+{begin_address,10'd0};
                            state<=GAIN;
                        end else begin
                            // MAME stops the voice before gain/mix/envelope on this sample.
                            next_address<=advanced_address;next_envelope_volume<=env;
                            next_envelope_stage<=stage;ended<=1;state<=RESULT;
                        end
                    end else begin next_address<=advanced_address;state<=GAIN;end
                end
                GAIN: begin
                    scaled_sample<=gain_product>>>8;
                    rate_delta_hold<=rate_product>>>16;
                    level<=0;
                    state<=flags[2]?ENVELOPE:PAN;
                end
                ENVELOPE: begin
                    if (level!=3) rate_delta_hold<=rate_product>>>16;
                    if (stage[{1'b0,level}]) begin
                        env<=updated_envelope;
                        if ((rate_delta>0 && ((updated_envelope>>>16)&32'h7f)>=32'(target)) ||
                            (rate_delta<0 && ((updated_envelope>>>16)&32'h7f)<=32'(target)))
                            stage<=shifted_stage;
                    end
                    if (level==3) state<=PAN;
                    else level<=level+1;
                end
                PAN: begin
                    pan_left_low<=scaled_sample[15:0]*lvol;
                    pan_right_low<=scaled_sample[15:0]*rvol;
                    pan_left_high<=$signed(scaled_sample[23:16])*$signed({1'b0,lvol});
                    pan_right_high<=$signed(scaled_sample[23:16])*$signed({1'b0,rvol});
                    state<=PAN_RESULT;
                end
                PAN_RESULT: begin
                    left_contribution<=pan_left>>>8;right_contribution<=pan_right>>>8;
                    next_envelope_volume<=env;next_envelope_stage<=stage;
                    state<=RESULT;
                end
                RESULT: if (result_ready) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
