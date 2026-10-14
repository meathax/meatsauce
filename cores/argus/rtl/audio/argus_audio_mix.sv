// Reference route ratio FM .50 : each PSG .15; Butasan doubles both.
// YMFM SSG full scale is 16382, so a normalized PSG byte represents 16382/255.
// Weights are 4x the original (FM 1/2, PSG 0.15 each, matching MAME's route
// gains); the 1/4 master headroom made every game far too quiet. The output
// saturates, and even Butasan's doubled worst case stays below 2^31 before the
// exact /20400 divider.
module argus_audio_mix (
    input wire [1:0] game_id,
    input wire signed [15:0] fm0, fm1,
    input wire [7:0] a0, b0, c0, a1, b1, c1,
    output reg signed [15:0] mixed
);
    reg signed [17:0] fm_sum;
    reg [10:0] psg_sum;
    reg signed [31:0] weighted, scaled;
    always @* begin
        fm_sum = {{2{fm0[15]}}, fm0};
        psg_sum = {3'd0,a0} + {3'd0,b0} + {3'd0,c0};
        if (game_id == 1 || game_id == 2) begin
            fm_sum = fm_sum + {{2{fm1[15]}},fm1};
            psg_sum = psg_sum + {3'd0,a1} + {3'd0,b1} + {3'd0,c1};
        end
        // Common denominator20400: FM /8 and PSG *16382/255 *3/80.
        weighted = ({{14{fm_sum[17]}},fm_sum} * 32'sd10200) +
                   ($signed({21'd0,psg_sum}) * 32'sd196584);
        if (game_id == 2) weighted = weighted <<< 1;
        scaled = weighted / 32'sd20400;
        if (game_id == 3) mixed = 0;
        else if (scaled > 32'sd32767) mixed = 16'sh7fff;
        else if (scaled < -32'sd32768) mixed = 16'sh8000;
        else mixed = scaled[15:0];
    end
endmodule

// Exact signed /20400 with one reciprocal multiply and one correction.
// ceil(2^32/20400)=210538. For 0<=n<=2^31 its estimate exceeds floor(n/20400)
// by at most one. Correcting q*20400>n preserves truncation toward zero.
// Each enabled clock advances the pipeline; pause holds its data and validity.
module argus_audio_divide_pipeline (
    input wire clk_sys, reset, enable, capture, mute,
    input wire signed [31:0] weighted,
    output reg signed [15:0] mixed,
    output reg mixed_valid
);
    wire [31:0] magnitude = weighted[31] ? $unsigned(-weighted) : $unsigned(weighted);
    reg [49:0] reciprocal_q;
    reg [31:0] magnitude_q;
    reg negative_q, mute_q, valid_q;
    wire [17:0] trial = reciprocal_q[49:32];
    wire [32:0] trial_product = {15'd0,trial} * 33'd20400;
    wire [17:0] quotient = trial - (trial_product > {1'b0,magnitude_q} ? 18'd1 : 18'd0);
    wire signed [31:0] signed_quotient = negative_q ?
        -$signed({14'd0,quotient}) : $signed({14'd0,quotient});
    always @(posedge clk_sys) begin
        if (reset) begin
            reciprocal_q <= 0;
            magnitude_q <= 0;
            negative_q <= 0;
            mute_q <= 0;
            valid_q <= 0;
            mixed <= 0;
            mixed_valid <= 0;
        end else if (enable) begin
            valid_q <= capture;
            mixed_valid <= valid_q;
            if (capture) begin
                reciprocal_q <= magnitude * 50'd210538;
                magnitude_q <= magnitude;
                negative_q <= weighted[31];
                mute_q <= mute;
            end
            if (valid_q) begin
                if (mute_q) mixed <= 0;
                else if (signed_quotient > 32'sd32767) mixed <= 16'sh7fff;
                else if (signed_quotient < -32'sd32768) mixed <= 16'sh8000;
                else mixed <= signed_quotient[15:0];
            end
        end
    end
endmodule

// The original combinational module above remains the arithmetic reference.
// This implementation captures exactly its inputs on capture and produces the
// same integer result three enabled clocks later, without adding a clock domain.
module argus_audio_mix_pipeline (
    input wire clk_sys, reset, enable, capture,
    input wire [1:0] game_id,
    input wire signed [15:0] fm0, fm1,
    input wire [7:0] a0, b0, c0, a1, b1, c1,
    output wire signed [15:0] mixed,
    output wire mixed_valid
);
    reg signed [17:0] fm_sum_d, fm_sum_q;
    reg [10:0] psg_sum_d, psg_sum_q;
    reg signed [31:0] weighted_d, weighted_q;
    reg double_q, mute0_q, mute1_q, valid0_q, valid1_q;
    always @* begin
        fm_sum_d = {{2{fm0[15]}},fm0};
        psg_sum_d = {3'd0,a0} + {3'd0,b0} + {3'd0,c0};
        if (game_id == 1 || game_id == 2) begin
            fm_sum_d = fm_sum_d + {{2{fm1[15]}},fm1};
            psg_sum_d = psg_sum_d + {3'd0,a1} + {3'd0,b1} + {3'd0,c1};
        end
        weighted_d = ({{14{fm_sum_q[17]}},fm_sum_q} * 32'sd10200) +
                     ($signed({21'd0,psg_sum_q}) * 32'sd196584);
        if (double_q) weighted_d = weighted_d <<< 1;
    end
    always @(posedge clk_sys) begin
        if (reset) begin
            fm_sum_q <= 0;
            psg_sum_q <= 0;
            weighted_q <= 0;
            double_q <= 0;
            mute0_q <= 0;
            mute1_q <= 0;
            valid0_q <= 0;
            valid1_q <= 0;
        end else if (enable) begin
            valid0_q <= capture;
            valid1_q <= valid0_q;
            if (capture) begin
                fm_sum_q <= fm_sum_d;
                psg_sum_q <= psg_sum_d;
                double_q <= game_id == 2;
                mute0_q <= game_id == 3;
            end
            if (valid0_q) begin
                weighted_q <= weighted_d;
                mute1_q <= mute0_q;
            end
        end
    end
    argus_audio_divide_pipeline divide (
        .clk_sys(clk_sys), .reset(reset), .enable(enable), .capture(valid1_q),
        .mute(mute1_q), .weighted(weighted_q), .mixed(mixed), .mixed_valid(mixed_valid)
    );
endmodule
