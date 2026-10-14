// Sega System Multi 32 stereo output mixer.
// Keep the route ratios used by the core, but accumulate at full precision and
// saturate after gain scaling so loud legal samples cannot wrap polarity.
//
// Exact MAME route gains (segas32.cpp): cross-routed YM 0.15 + MultiPCM 0.35,
// divide by 20. Multi 32 cross-routes BOTH the YM and the MultiPCM
// (multipcm add_route(1,"sleft") / add_route(0,"sright") -- stream 1 -> left,
// stream 0 -> right -- the same cross as the YM).
module s32_audio_mix (
    input  signed     [15:0] fm1_l,
    input  signed     [15:0] fm1_r,
    input  signed     [15:0] mp_l,
    input  signed     [15:0] mp_r,
    output signed     [15:0] audio_l,
    output signed     [15:0] audio_r
);

localparam logic signed [19:0] AUDIO_MAX = 20'sd32767;
localparam logic signed [19:0] AUDIO_MIN = -20'sd32768;

wire signed [19:0] fm1_l_w = {{4{fm1_l[15]}}, fm1_l};
wire signed [19:0] fm1_r_w = {{4{fm1_r[15]}}, fm1_r};
wire signed [19:0] mp_l_w  = {{4{mp_l[15]}},  mp_l};
wire signed [19:0] mp_r_w  = {{4{mp_r[15]}},  mp_r};

wire signed [19:0] mix_l = (fm1_r_w <<< 1) + fm1_r_w + (mp_r_w <<< 3) - mp_r_w;
wire signed [19:0] mix_r = (fm1_l_w <<< 1) + fm1_l_w + (mp_l_w <<< 3) - mp_l_w;

// Exact unsigned divide-by-20, derived from the divide-by-10 network this
// replaced (Hacker's Delight-style shift/add reciprocal, refined by one
// remainder-correction step) plus the floor-division identity
// floor(m / (10*2)) == floor(floor(m/10) / 2) for non-negative integers m.
// The intermediate quotient10 is unsigned and >=0, so the final >>1 is an
// exact, lossless floor by 2 -- no separate rounding correction is needed for
// the extra factor. Applying magnitude/sign split first, then re-signing only
// once at the end, matches Verilog's signed `/` truncate-toward-zero
// semantics exactly, and keeps Quartus from inferring an lpm_divide block.
function automatic signed [19:0] divide_by_20_exact(input logic signed [19:0] sample);
    logic        negative;
    logic [19:0] magnitude;
    logic [19:0] quotient10;
    logic [19:0] remainder;
    logic [19:0] quotient20;
    begin
        negative   = sample[19];
        magnitude  = negative ? (~sample + 20'd1) : sample;
        quotient10 = (magnitude >> 1) + (magnitude >> 2);
        quotient10 = quotient10 + (quotient10 >> 4);
        quotient10 = quotient10 + (quotient10 >> 8);
        quotient10 = quotient10 + (quotient10 >> 16);
        quotient10 = quotient10 >> 3;
        remainder  = magnitude - (quotient10 << 3) - (quotient10 << 1);
        quotient10 = quotient10 + ((remainder + 20'd6) >> 4);
        quotient20 = quotient10 >> 1;
        divide_by_20_exact = negative ? -$signed(quotient20) : $signed(quotient20);
    end
endfunction

function automatic signed [15:0] scale_and_clip(input logic signed [19:0] sample);
    logic signed [19:0] scaled;
    begin
        scaled = divide_by_20_exact(sample);
        if (scaled > AUDIO_MAX)      scale_and_clip = 16'sh7fff;
        else if (scaled < AUDIO_MIN) scale_and_clip = 16'sh8000;
        else                         scale_and_clip = scaled[15:0];
    end
endfunction

assign audio_l = scale_and_clip(mix_l);
assign audio_r = scale_and_clip(mix_r);

endmodule
