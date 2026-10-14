// =============================================================================
// williams_bg_biquad.sv -- sequential Direct-Form-II biquad section, used to
// model the two op-amp stages of the Williams D-11581 CVSD output filter.
//
// STRUCTURE (matches MAME's filter_biquad_device exactly)
// -----------------------------------------------------------------------------
// MAME 0.289 `src/devices/sound/flt_biquad.cpp`, `filter_biquad_device::step()`:
//     w0 = (-a1 * w1) + (-a2 * w2) + x
//     y  = ( b0 * w0) + ( b1 * w1) + ( b2 * w2)
//     w2 = w1; w1 = w0;
// and `recalc()` folds the analog stage's voltage gain into b0/b1/b2
// (`m_bx *= m_gain`) rather than applying it separately. This module reproduces
// that structure and that convention: B0/B1/B2 passed in already include the
// stage gain (and hence its inverting sign), and A1/A2 use MAME's sign
// convention (note the two minus signs in the w0 line above).
//
// ARITHMETIC
// -----------------------------------------------------------------------------
// One signed multiplier, time-multiplexed over 5 MAC steps, started by a
// `tick` pulse (6 clk cycles per sample). At the board's 48 kHz filter rate and
// a 40 MHz `clk` there are ~833 clk cycles per sample, so the sequential engine
// is free; the point of doing it sequentially is that each biquad costs ONE DSP
// block instead of five (CLAUDE.md, "DSP block exhaustion is usually an
// oversized multiplier operand"). Operand widths are held at their
// analytically-derived minimum for the same reason: W_STATE (20) x COEF_W (16).
//
// Coefficients are signed Q2.14 (range [-2, +2)); the largest magnitude either
// stage of this filter needs is 1.392 (stage 2's a1).
//
// The Direct-Form-II state `w` carries the section's pole gain 1/(1+a1+a2),
// which for stage 2 is ~6.96 -- w is materially LARGER than either the input or
// the output and must be sized from that product, not from the I/O width. Both
// w0 and the output saturate rather than wrap, so a numerical surprise degrades
// gracefully instead of inverting the signal.
// =============================================================================

`default_nettype none

module williams_bg_biquad #(
    parameter int W_IN    = 18,   // signed input width
    parameter int W_OUT   = 18,   // signed output width
    parameter int W_STATE = 20,   // signed Direct-Form-II state width
    parameter int COEF_Q  = 14,   // fractional bits of the coefficients
    parameter logic signed [15:0] B0 = 16'sd0,
    parameter logic signed [15:0] B1 = 16'sd0,
    parameter logic signed [15:0] B2 = 16'sd0,
    parameter logic signed [15:0] A1 = 16'sd0,
    parameter logic signed [15:0] A2 = 16'sd0
) (
    input  logic                     clk,
    input  logic                     rst,     // synchronous, active high
    input  logic                     tick,    // start one sample step
    input  logic signed [W_IN-1:0]   din,
    output logic signed [W_OUT-1:0]  dout,
    output logic                     done     // 1-clk pulse, dout updated
);

    localparam int PROD_W = W_STATE + 16;        // exact signed product width
    localparam int ACC_W  = PROD_W + 4;          // + accumulation headroom
    localparam int SH_W   = ACC_W - COEF_Q;      // width after the >>> COEF_Q

    logic signed [W_STATE-1:0] w0, w1, w2;
    logic signed [ACC_W-1:0]   acc;
    logic [2:0]                st;

    // ---- shared multiplier ---------------------------------------------------
    // Operands are exactly W_STATE x 16; prod_raw is their exact product width,
    // so Quartus builds one correctly-sized multiplier rather than inferring a
    // pair of cascaded DSP blocks from an over-wide operand.
    logic signed [W_STATE-1:0] mula;
    logic signed [15:0]        mulb;
    logic signed [PROD_W-1:0]  prod_raw;
    logic signed [ACC_W-1:0]   prod;

    always_comb begin
        case (st)
            3'd1:    begin mula = w1; mulb = A1; end
            3'd2:    begin mula = w2; mulb = A2; end
            3'd3:    begin mula = w0; mulb = B0; end
            3'd4:    begin mula = w1; mulb = B1; end
            default: begin mula = w2; mulb = B2; end
        endcase
    end

    assign prod_raw = mula * mulb;
    assign prod     = {{(ACC_W-PROD_W){prod_raw[PROD_W-1]}}, prod_raw};

    // ---- saturating arithmetic right-shift ------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */   // v[COEF_Q-1:0] is discarded by the shift
    function automatic logic signed [W_STATE-1:0] sat_state(input logic signed [ACC_W-1:0] v);
        logic signed [SH_W-1:0] s;
        s = v[ACC_W-1:COEF_Q];                       // == v >>> COEF_Q, exactly
        if (!s[SH_W-1] &&  (|s[SH_W-2:W_STATE-1]))
            sat_state = {1'b0, {(W_STATE-1){1'b1}}};
        else if (s[SH_W-1] && !(&s[SH_W-2:W_STATE-1]))
            sat_state = {1'b1, {(W_STATE-1){1'b0}}};
        else
            sat_state = s[W_STATE-1:0];
    endfunction

    function automatic logic signed [W_OUT-1:0] sat_out(input logic signed [ACC_W-1:0] v);
        logic signed [SH_W-1:0] s;
        s = v[ACC_W-1:COEF_Q];
        if (!s[SH_W-1] &&  (|s[SH_W-2:W_OUT-1]))
            sat_out = {1'b0, {(W_OUT-1){1'b1}}};
        else if (s[SH_W-1] && !(&s[SH_W-2:W_OUT-1]))
            sat_out = {1'b1, {(W_OUT-1){1'b0}}};
        else
            sat_out = s[W_OUT-1:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic signed [ACC_W-1:0] din_scaled;
    assign din_scaled = $signed({{(ACC_W-W_IN){din[W_IN-1]}}, din}) <<< COEF_Q;

    always_ff @(posedge clk) begin
        if (rst) begin
            w0   <= '0;
            w1   <= '0;
            w2   <= '0;
            acc  <= '0;
            st   <= 3'd0;
            dout <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                3'd0: if (tick) begin
                          acc <= din_scaled;            // acc = x << COEF_Q
                          st  <= 3'd1;
                      end
                3'd1: begin acc <= acc - prod;            st <= 3'd2; end  // -a1*w1
                3'd2: begin w0  <= sat_state(acc - prod); st <= 3'd3; end  // -a2*w2
                3'd3: begin acc <= prod;                  st <= 3'd4; end  //  b0*w0
                3'd4: begin acc <= acc + prod;            st <= 3'd5; end  //  b1*w1
                default: begin                                             //  b2*w2
                          dout <= sat_out(acc + prod);
                          w2   <= w1;
                          w1   <= w0;
                          done <= 1'b1;
                          st   <= 3'd0;
                      end
            endcase
        end
    end

endmodule

`default_nettype wire
