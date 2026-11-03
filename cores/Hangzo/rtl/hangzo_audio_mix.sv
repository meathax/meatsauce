// SPDX-License-Identifier: GPL-3.0-or-later
// rohga.cpp: YM L/R .36, OKI1 mono .46, OKI2 mono .18.
// YM is signed16/32768; raw summed JT6295 voices are signed14/2048.
// Convert OKI to YM units (x16), sum before a single truncation, then clip.
`timescale 1ns/1ns
module hangzo_audio_mix (
    input wire clk,reset,sample_ce,
    input wire signed [15:0] ym_left,ym_right,
    input wire signed [13:0] oki1,oki2,
    output reg signed [15:0] left,right,
    output reg sample
);
    // Keep the original signed-24 arithmetic and grouping. One input token is
    // accepted on each sample_ce edge; all stages below can accept one token
    // per clk, including consecutive sample_ce cycles.
    wire signed [23:0] yl={{8{ym_left[15]}},ym_left};
    wire signed [23:0] yr={{8{ym_right[15]}},ym_right};
    wire signed [23:0] o1={{10{oki1[13]}},oki1};
    wire signed [23:0] o2={{10{oki2[13]}},oki2};

    reg signed [23:0] p_o1,p_o2,p_yl,p_yr;
    reg signed [23:0] mono_q,p_yl_d1,p_yr_d1,sum_l_q,sum_r_q;
    reg [9:0] valid;

    // Restoring division by 50, four numerator bits per registered stage.
    // remainder is always below 50; shifting one bit therefore needs 7 bits.
    function automatic [10:0] divide_four;
        input [3:0] numerator_bits;
        input [6:0] remainder_in;
        reg [6:0] rem_work;
        reg [6:0] trial;
        reg [3:0] quotient_bits;
        begin
            rem_work = remainder_in;
            quotient_bits = 4'b0;

            trial = {rem_work[5:0], numerator_bits[3]};
            if (trial >= 7'd50) begin
                rem_work = trial - 7'd50;
                quotient_bits[3] = 1'b1;
            end else rem_work = trial;

            trial = {rem_work[5:0], numerator_bits[2]};
            if (trial >= 7'd50) begin
                rem_work = trial - 7'd50;
                quotient_bits[2] = 1'b1;
            end else rem_work = trial;

            trial = {rem_work[5:0], numerator_bits[1]};
            if (trial >= 7'd50) begin
                rem_work = trial - 7'd50;
                quotient_bits[1] = 1'b1;
            end else rem_work = trial;

            trial = {rem_work[5:0], numerator_bits[0]};
            if (trial >= 7'd50) begin
                rem_work = trial - 7'd50;
                quotient_bits[0] = 1'b1;
            end else rem_work = trial;

            divide_four = {rem_work, quotient_bits};
        end
    endfunction

    reg [23:0] magnitude_l [3:9];
    reg [23:0] magnitude_r [3:9];
    reg [6:0] remainder_l [3:9];
    reg [6:0] remainder_r [3:9];
    reg [23:0] quotient_l [3:9];
    reg [23:0] quotient_r [3:9];
    reg negative_l [3:9];
    reg negative_r [3:9];

    wire signed [23:0] restored_l = negative_l[9] ? -$signed(quotient_l[9]) : $signed(quotient_l[9]);
    wire signed [23:0] restored_r = negative_r[9] ? -$signed(quotient_r[9]) : $signed(quotient_r[9]);

    function automatic signed [15:0] clip;
        input signed [23:0] value;
        begin
            if(value > 24'sd32767) clip=16'sh7fff;
            else if(value < -24'sd32768) clip=16'sh8000;
            else clip=value[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if(reset) begin
            valid[3:0] <= 4'b0;
            left <= 0;
            right <= 0;
            sample <= 0;
        end else begin
            valid[0] <= sample_ce;
            valid[1] <= valid[0];
            valid[2] <= valid[1];
            valid[3] <= valid[2];
            sample <= valid[9];

            if(sample_ce) begin
                p_o1 <= o1 * 24'sd368;
                p_o2 <= o2 * 24'sd144;
                p_yl <= yl * 24'sd18;
                p_yr <= yr * 24'sd18;
            end
            if(valid[0]) begin
                mono_q <= p_o1 + p_o2;
                p_yl_d1 <= p_yl;
                p_yr_d1 <= p_yr;
            end
            if(valid[1]) begin
                sum_l_q <= p_yl_d1 + mono_q;
                sum_r_q <= p_yr_d1 + mono_q;
            end
            if(valid[2]) begin
                negative_l[3] <= sum_l_q[23];
                negative_r[3] <= sum_r_q[23];
                magnitude_l[3] <= sum_l_q[23] ? -sum_l_q : sum_l_q;
                magnitude_r[3] <= sum_r_q[23] ? -sum_r_q : sum_r_q;
                remainder_l[3] <= 0;
                remainder_r[3] <= 0;
                quotient_l[3] <= 0;
                quotient_r[3] <= 0;
            end
            if(valid[9]) begin
                left <= clip(restored_l);
                right <= clip(restored_r);
            end
        end
    end

    genvar g;
    generate
        for(g=4;g<=9;g=g+1) begin: divide_pipe
            wire [10:0] div_l = divide_four(magnitude_l[g-1][23:20],remainder_l[g-1]);
            wire [10:0] div_r = divide_four(magnitude_r[g-1][23:20],remainder_r[g-1]);
            always @(posedge clk) begin
                if(reset) begin
                    valid[g] <= 1'b0;
                end else begin
                    valid[g] <= valid[g-1];
                    if(valid[g-1]) begin
                        magnitude_l[g] <= {magnitude_l[g-1][19:0],4'b0};
                        magnitude_r[g] <= {magnitude_r[g-1][19:0],4'b0};
                        remainder_l[g] <= div_l[10:4];
                        remainder_r[g] <= div_r[10:4];
                        quotient_l[g] <= {quotient_l[g-1][19:0],div_l[3:0]};
                        quotient_r[g] <= {quotient_r[g-1][19:0],div_r[3:0]};
                        negative_l[g] <= negative_l[g-1];
                        negative_r[g] <= negative_r[g-1];
                    end
                end
            end
        end
    endgenerate
endmodule
