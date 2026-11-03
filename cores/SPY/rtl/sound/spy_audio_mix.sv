// SPDX-License-Identifier: GPL-3.0-or-later
// Exact SPY gains, with a ten-active-clock pipeline at 48 MHz.
module spy_audio_mix(
    input logic clk, reset, pause, sample_tick,
    input logic signed [15:0] ym_audio,
    input logic signed [10:0] pcm0_a, pcm0_b, pcm1_a, pcm1_b,
    output logic signed [15:0] audio,
    output logic sample_valid, clip
);
    localparam integer LATENCY = 10;
    logic v_sum, v_scale, v_mag, v_restore, v_mix;
    logic signed [11:0] sum0, sum1;
    logic signed [17:0] scaled0, scaled1, restored0, restored1;
    logic signed [15:0] ym_sum, ym_scale, ym_mag, ym_restore;
    logic sign_mag0, sign_mag1;
    // State packs remaining dividend[38:21], remainder[20:18], quotient[17:0].
    logic [38:0] mag0, mag1;
    logic [38:0] div0[0:4], div1[0:4];
    logic [4:0] div_valid, sign0, sign1;
    logic signed [15:0] ym_div[0:4];
    logic signed [18:0] mixed;

    // One restoring division step. Remainder is always 0..4; trial is 0..9.
    function automatic [38:0] div_bit(input [38:0] state);
        reg [3:0] trial;
        reg [2:0] remainder;
        reg quotient_bit;
        begin
            trial = {state[20:18],state[38]};
            quotient_bit = trial >= 4'd5;
            remainder = quotient_bit ? 3'(trial-4'd5) : trial[2:0];
            div_bit = {state[37:21],1'b0,remainder,state[16:0],quotient_bit};
        end
    endfunction
    function automatic [38:0] div_four(input [38:0] state);
        div_four = div_bit(div_bit(div_bit(div_bit(state))));
    endfunction
    function automatic [38:0] div_two(input [38:0] state);
        div_two = div_bit(div_bit(state));
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            v_sum <= 0; v_scale <= 0; v_mag <= 0;
            sum0 <= 0; sum1 <= 0; scaled0 <= 0; scaled1 <= 0;
            ym_sum <= 0; ym_scale <= 0; ym_mag <= 0;
            mag0 <= 0; mag1 <= 0; sign_mag0 <= 0; sign_mag1 <= 0;
        end else if (!pause) begin
            v_sum <= sample_tick; v_scale <= v_sum; v_mag <= v_scale;
            if (sample_tick) begin
                // Explicit sign extension preserves the complete two-channel sum.
                sum0 <= $signed({pcm0_a[10],pcm0_a}) + $signed({pcm0_b[10],pcm0_b});
                sum1 <= $signed({pcm1_a[10],pcm1_a}) + $signed({pcm1_b[10],pcm1_b});
                ym_sum <= ym_audio;
            end
            if (v_sum) begin
                scaled0 <= sum0 * 18'sd34;
                scaled1 <= sum1 * 18'sd34;
                ym_scale <= ym_sum;
            end
            if (v_scale) begin
                mag0 <= {scaled0[17] ? $unsigned(-scaled0) : $unsigned(scaled0),21'd0};
                mag1 <= {scaled1[17] ? $unsigned(-scaled1) : $unsigned(scaled1),21'd0};
                sign_mag0 <= scaled0[17]; sign_mag1 <= scaled1[17];
                ym_mag <= ym_scale;
            end
        end
    end

    genvar stage;
    generate for (stage=0; stage<5; stage=stage+1) begin: divide_stage
        wire [38:0] in0, in1;
        wire in_valid, in_sign0, in_sign1;
        wire signed [15:0] in_ym;
        if (stage==0) begin: first_input
            assign in0=mag0; assign in1=mag1; assign in_valid=v_mag;
            assign in_sign0=sign_mag0; assign in_sign1=sign_mag1; assign in_ym=ym_mag;
        end else begin: previous_input
            assign in0=div0[stage-1]; assign in1=div1[stage-1];
            assign in_valid=div_valid[stage-1];
            assign in_sign0=sign0[stage-1]; assign in_sign1=sign1[stage-1];
            assign in_ym=ym_div[stage-1];
        end
        always_ff @(posedge clk) begin
            if (reset) begin
                div0[stage] <= 0; div1[stage] <= 0; div_valid[stage] <= 0;
                sign0[stage] <= 0; sign1[stage] <= 0; ym_div[stage] <= 0;
            end else if (!pause) begin
                div_valid[stage] <= in_valid;
                if (in_valid) begin
                    div0[stage] <= stage==4 ? div_two(in0) : div_four(in0);
                    div1[stage] <= stage==4 ? div_two(in1) : div_four(in1);
                    sign0[stage] <= in_sign0; sign1[stage] <= in_sign1;
                    ym_div[stage] <= in_ym;
                end
            end
        end
    end endgenerate

    always_ff @(posedge clk) begin
        if (reset) begin
            v_restore <= 0; v_mix <= 0;
            restored0 <= 0; restored1 <= 0; ym_restore <= 0;
            mixed <= 0; audio <= 0; sample_valid <= 0; clip <= 0;
        end else begin
            sample_valid <= !pause && v_mix;
            if (!pause) begin
                v_restore <= div_valid[4]; v_mix <= v_restore;
                if (div_valid[4]) begin
                    // Divide magnitudes then restore the sign: signed /5 truncates
                    // toward zero exactly, including all negative remainders.
                    restored0 <= sign0[4] ? -$signed(div0[4][17:0]) : $signed(div0[4][17:0]);
                    restored1 <= sign1[4] ? -$signed(div1[4][17:0]) : $signed(div1[4][17:0]);
                    ym_restore <= ym_div[4];
                end
                if (v_restore) begin
                    mixed <= $signed({{3{ym_restore[15]}},ym_restore}) +
                             $signed({restored0[17],restored0}) +
                             $signed({restored1[17],restored1});
                end
                if (v_mix) begin
                    clip <= mixed > 19'sd32767 || mixed < -19'sd32768;
                    if (mixed > 19'sd32767) audio <= 16'sh7fff;
                    else if (mixed < -19'sd32768) audio <= 16'sh8000;
                    else audio <= mixed[15:0];
                end
            end
        end
    end
endmodule
