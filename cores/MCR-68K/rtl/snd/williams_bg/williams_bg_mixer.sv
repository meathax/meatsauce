// =============================================================================
// williams_bg_mixer.sv -- Williams D-11581 output mixer (the MC1458 summing
// amplifier U18B and its four input resistors).
//
// EVIDENCE
// -----------------------------------------------------------------------------
// The board sums four sources into one MC1458 inverting summing node. The only
// difference between the D-11581 (System 11, used by Arch Rivals) and the
// D-11581-20xx/400xx (System 11C, used by Pigskin) is the value of those input
// resistors -- s11c_bg.cpp's own header table:
//
//     schematic P/N     16-8999 Rev -      16-8999 Rev E / 16-9138
//     oldstyle  P/N     D-11581 (S11)      D-11581-20xx/400xx (S11C)
//     CPU_SOUND         R12  2.2k          R12  4.7k        <- mainboard audio in
//     YM2151 CH1        R14  10k           R14  20k
//     YM2151 CH2        R15  10k           R15  20k
//     MC1408 DAC        R16  6.3k          R16  13k
//     CVSD              R13  4.99k 1%      R13  4.99k 1%
//     MC1458 Feedback   R17  10k           R17  10k
//
// i.e. S11C doubles every input resistor EXCEPT the CVSD one, which is what
// makes the CVSD roughly twice as loud on System 11C boards.
//
// The weights used here are MAME's own precomputed `add_route` gains, taken
// verbatim from the two `device_add_mconfig` functions so that the RELATIVE mix
// is bit-comparable with MAME:
//
//   S11  (s11_bg_device::device_add_mconfig,  s11c_bg.cpp:429-446)
//       dac 0.1566, ym ch0 0.0987, ym ch1 0.0987, cvsd_filter2 0.1977 * 4.0
//   S11C (s11c_bg_device::device_add_mconfig, s11c_bg.cpp:409-426)
//       dac 0.1304, ym ch0 0.08473, ym ch1 0.08473, cvsd_filter2 0.3396 * 4.0
//
// The `* 4.0` on the CVSD route is MAME's compensation for the matching
// `1.0/4.0` it applies when routing HC55516 INTO the filter chain ("to prevent
// massive clipping issues"). williams_bg.sv reproduces that same 1/4 pre-scale
// on the filter input, so the *4 belongs here, exactly as in MAME. The pair is
// numerically transparent -- it is a headroom device, not a hardware feature.
//
// The mainboard audio-passthrough input (R12) is NOT modelled: on MCR-68k the
// main board has no analog audio of its own to feed into J3, and mcr68.cpp
// routes the whole s11(c)_bg device straight to the speaker with no input
// route. That is the reason MAME's own comment says to multiply by 1/0.6395
// (S11C) or 1/0.5516 (S11) "to get the relative volume values if there is no
// audio input used at all" -- a pure output-level scaling that changes nothing
// about the mix between the four modelled sources. It is deliberately NOT
// applied here; absolute output level is an integration-level decision (see
// doc/integration_requests/williams_bg.md).
//
// ARITHMETIC
// -----------------------------------------------------------------------------
// Weights are unsigned-magnitude signed Q2.14 constants (the largest is S11C's
// CVSD weight 1.3584). One time-multiplexed signed multiplier, 4 MAC steps,
// started by `tick` -- one DSP block, same rationale as williams_bg_biquad.sv.
//
// The sum SATURATES to 16-bit signed. Worst-case full-scale-on-every-input sums
// to about +/-38.7k (S11) / +/-56.4k (S11C), so clipping is reachable in
// principle -- as it is in MAME, whose mixer sums the same gains into a
// stream that clips at the speaker. Saturation (not wrap) is used so that the
// failure mode is analog-like.
//
// `s11c` is a STATIC configuration level (mcr68_game_profile.svh's
// `williams_s11c`), held stable while the board is out of reset. It selects
// between two constant weight sets -- it does not gate a clock and is not
// per-cycle control.
// =============================================================================

`default_nettype none

module williams_bg_mixer (
    input  logic               clk,
    input  logic               rst,        // synchronous, active high
    input  logic               s11c,       // 0 = D-11581 (S11), 1 = D-11581-20xx (S11C)
    input  logic               tick,       // start one mix step

    input  logic signed [17:0] dac_s,      // MC1408 code, already centred/scaled
    input  logic signed [15:0] ym_l,       // YM2151 CH0
    input  logic signed [15:0] ym_r,       // YM2151 CH1
    input  logic signed [17:0] cvsd_f,     // CVSD after both filter stages

    output logic signed [15:0] audio,
    output logic               done        // 1-clk pulse, `audio` updated
);

    localparam int COEF_Q = 14;
    localparam int PROD_W = 18 + 16;
    localparam int ACC_W  = PROD_W + 4;
    localparam int SH_W   = ACC_W - COEF_Q;

    // Q2.14 weights. round(w * 16384):
    //   S11 : 0.1566 ->  2566 | 0.0987 ->  1617 | 0.1977*4 = 0.7908 -> 12957
    //   S11C: 0.1304 ->  2136 | 0.08473 -> 1388 | 0.3396*4 = 1.3584 -> 22256
    localparam logic signed [15:0] W_DAC_S11   = 16'sd2566;
    localparam logic signed [15:0] W_YM_S11    = 16'sd1617;
    localparam logic signed [15:0] W_CVSD_S11  = 16'sd12957;
    localparam logic signed [15:0] W_DAC_S11C  = 16'sd2136;
    localparam logic signed [15:0] W_YM_S11C   = 16'sd1388;
    localparam logic signed [15:0] W_CVSD_S11C = 16'sd22256;

    logic signed [15:0] w_dac, w_ym, w_cvsd;
    assign w_dac  = s11c ? W_DAC_S11C  : W_DAC_S11;
    assign w_ym   = s11c ? W_YM_S11C   : W_YM_S11;
    assign w_cvsd = s11c ? W_CVSD_S11C : W_CVSD_S11;

    // Latched operands, so a source changing mid-mix cannot split one output
    // sample across two input snapshots.
    logic signed [17:0] q_dac, q_yml, q_ymr, q_cvsd;

    logic signed [17:0] mula;
    logic signed [15:0] mulb;
    logic signed [PROD_W-1:0] prod_raw;
    logic signed [ACC_W-1:0]  prod;
    logic signed [ACC_W-1:0]  acc;
    logic [2:0]               st;

    always_comb begin
        case (st)
            3'd1:    begin mula = q_dac;  mulb = w_dac;  end
            3'd2:    begin mula = q_yml;  mulb = w_ym;   end
            3'd3:    begin mula = q_ymr;  mulb = w_ym;   end
            default: begin mula = q_cvsd; mulb = w_cvsd; end
        endcase
    end

    assign prod_raw = mula * mulb;
    assign prod     = {{(ACC_W-PROD_W){prod_raw[PROD_W-1]}}, prod_raw};

    /* verilator lint_off UNUSEDSIGNAL */   // v[COEF_Q-1:0] is discarded by the shift
    function automatic logic signed [15:0] sat16(input logic signed [ACC_W-1:0] v);
        logic signed [SH_W-1:0] s;
        s = v[ACC_W-1:COEF_Q];
        if (!s[SH_W-1] &&  (|s[SH_W-2:15]))      sat16 = 16'sh7FFF;
        else if (s[SH_W-1] && !(&s[SH_W-2:15]))  sat16 = 16'sh8000;
        else                                     sat16 = s[15:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (rst) begin
            q_dac  <= '0;
            q_yml  <= '0;
            q_ymr  <= '0;
            q_cvsd <= '0;
            acc    <= '0;
            st     <= 3'd0;
            audio  <= 16'sd0;
            done   <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                3'd0: if (tick) begin
                          q_dac  <= dac_s;
                          q_yml  <= {{2{ym_l[15]}}, ym_l};
                          q_ymr  <= {{2{ym_r[15]}}, ym_r};
                          q_cvsd <= cvsd_f;
                          st     <= 3'd1;
                      end
                3'd1: begin acc <= prod;       st <= 3'd2; end
                3'd2: begin acc <= acc + prod; st <= 3'd3; end
                3'd3: begin acc <= acc + prod; st <= 3'd4; end
                default: begin
                          audio <= sat16(acc + prod);
                          done  <= 1'b1;
                          st    <= 3'd0;
                      end
            endcase
        end
    end

endmodule

`default_nettype wire
