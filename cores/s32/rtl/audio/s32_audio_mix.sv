// Sega System 32 / Multi 32 stereo output mixer.
// Keep the route ratios used by the core, but accumulate at full precision and
// saturate after gain scaling so loud legal samples cannot wrap polarity.
module s32_audio_mix (
    input                    is_multi32,
    input  signed     [15:0] fm1_l,
    input  signed     [15:0] fm1_r,
    input  signed     [15:0] fm2_l,
    input  signed     [15:0] fm2_r,
    input  signed     [15:0] rf_l,
    input  signed     [15:0] rf_r,
    input  signed     [15:0] mp_l,
    input  signed     [15:0] mp_r,
    output signed     [15:0] audio_l,
    output signed     [15:0] audio_r
);

localparam logic signed [19:0] AUDIO_MAX = 20'sd32767;
localparam logic signed [19:0] AUDIO_MIN = -20'sd32768;

wire signed [19:0] fm1_l_w = {{4{fm1_l[15]}}, fm1_l};
wire signed [19:0] fm1_r_w = {{4{fm1_r[15]}}, fm1_r};
wire signed [19:0] fm2_l_w = {{4{fm2_l[15]}}, fm2_l};
wire signed [19:0] fm2_r_w = {{4{fm2_r[15]}}, fm2_r};
wire signed [19:0] rf_l_w  = {{4{rf_l[15]}},  rf_l};
wire signed [19:0] rf_r_w  = {{4{rf_r[15]}},  rf_r};
wire signed [19:0] mp_l_w  = {{4{mp_l[15]}},  mp_l};
wire signed [19:0] mp_r_w  = {{4{mp_r[15]}},  mp_r};

// Exact MAME route gains expressed as small integers:
// System 32: YM1 0.30 + YM2 0.30 + RF5C68 0.40 (divide by 10).
// Multi 32: cross-routed YM 0.15 + MultiPCM 0.35 (divide by 20).
// Multi 32 cross-routes BOTH the YM and the MultiPCM (MAME segas32.cpp:
// multipcm add_route(1,"sleft") / add_route(0,"sright") — stream 1 -> left,
// stream 0 -> right — the same cross as the YM).  mp channels were previously
// routed straight, mirroring the MultiPCM stereo image on Multi 32.
`ifdef S32_SYSTEM32_ONLY
`define S32_FIXED_SYSTEM32_AUDIO
`endif
`ifdef S32_FIXED_SYSTEM32_AUDIO
// Dedicated revisions are fixed to single-screen System 32 boards.
// Remove the Multi 32 routing cone at preprocessing time.
wire signed [19:0] mix_l = (fm1_l_w <<< 1) + fm1_l_w
                         + (fm2_l_w <<< 1) + fm2_l_w
                         + (rf_l_w <<< 2);
wire signed [19:0] mix_r = (fm1_r_w <<< 1) + fm1_r_w
                         + (fm2_r_w <<< 1) + fm2_r_w
                         + (rf_r_w <<< 2);
`else
wire signed [19:0] mix_l = is_multi32
    ? (fm1_r_w <<< 1) + fm1_r_w + (mp_r_w <<< 3) - mp_r_w
    : (fm1_l_w <<< 1) + fm1_l_w + (fm2_l_w <<< 1) + fm2_l_w
      + (rf_l_w <<< 2);
wire signed [19:0] mix_r = is_multi32
    ? (fm1_l_w <<< 1) + fm1_l_w + (mp_l_w <<< 3) - mp_l_w
    : (fm1_r_w <<< 1) + fm1_r_w + (fm2_r_w <<< 1) + fm2_r_w
      + (rf_r_w <<< 2);
`endif

`ifdef S32_FIXED_SYSTEM32_AUDIO
// Exact unsigned divide-by-10 from Hacker's Delight, applied to the magnitude
// and signed afterward so negative results truncate toward zero exactly like
// SystemVerilog signed `/ 10`. The complete input magnitude is 0..524288.
// This shift/add network prevents Quartus 17 from inferring the two general
// lpm_divide blocks produced by the runtime-selectable `/10` versus `/20` path.
function automatic signed [19:0] divide_by_10_exact(input logic signed [19:0] sample);
    logic        negative;
    logic [19:0] magnitude;
    logic [19:0] quotient;
    logic [19:0] remainder;
    begin
        negative  = sample[19];
        magnitude = negative ? (~sample + 20'd1) : sample;
        quotient  = (magnitude >> 1) + (magnitude >> 2);
        quotient  = quotient + (quotient >> 4);
        quotient  = quotient + (quotient >> 8);
        quotient  = quotient + (quotient >> 16);
        quotient  = quotient >> 3;
        remainder = magnitude - (quotient << 3) - (quotient << 1);
        quotient  = quotient + ((remainder + 20'd6) >> 4);
        divide_by_10_exact = negative ? -$signed(quotient) : $signed(quotient);
    end
endfunction
`endif
function automatic signed [15:0] scale_and_clip(input logic signed [19:0] sample);
    logic signed [19:0] scaled;
    begin
`ifdef S32_FIXED_SYSTEM32_AUDIO
        scaled = divide_by_10_exact(sample);
`else
        scaled = is_multi32 ? (sample / 20'sd20) : (sample / 20'sd10);
`endif
        if (scaled > AUDIO_MAX)      scale_and_clip = 16'sh7fff;
        else if (scaled < AUDIO_MIN) scale_and_clip = 16'sh8000;
        else                         scale_and_clip = scaled[15:0];
    end
endfunction

assign audio_l = scale_and_clip(mix_l);
assign audio_r = scale_and_clip(mix_r);

endmodule

`ifdef S32_FIXED_SYSTEM32_AUDIO
`undef S32_FIXED_SYSTEM32_AUDIO
`endif
