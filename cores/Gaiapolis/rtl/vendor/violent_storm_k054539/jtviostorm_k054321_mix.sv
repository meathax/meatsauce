/* SPDX-License-Identifier: GPL-2.0-only
 * Violent Storm's title-local digital board adapter.
 * Default WET_MIX=0 preserves the established title D/B output route.
 * WET_MIX=1 is an isolated FUNCTIONAL equal dry/wet reconstruction, not a
 * physically qualified board weight. Existing inferred K054321 Q4.12 curve
 * is unchanged. Native 054539 banks retain their own 16-bit wrap.
* The external board summer/clipping law is not physically qualified.
* OUTPUT_GAIN_SHIFT normalizes the MiSTer PCM output separately from the
* chip's native DSP. It does not change the ROM curves or native DAC words.
*/
module jtviostorm_k054321_mix #(parameter WET_MIX=0, parameter OUTPUT_GAIN_SHIFT=0)(
    input  logic               clk,
    input  logic               rst,
    input  logic               chip_a_valid,
    input  logic               chip_b_valid,
    input  logic               chip_a_enabled,
    input  logic               chip_b_enabled,
    input  logic        [15:0] chip_a_epoch,
    input  logic        [15:0] chip_b_epoch,
    input  logic signed [15:0] chip_a_dry_l,
    input  logic signed [15:0] chip_a_dry_r,
    input  logic signed [15:0] chip_a_wet_l,
    input  logic signed [15:0] chip_a_wet_r,
    input  logic signed [15:0] chip_b_dry_l,
    input  logic signed [15:0] chip_b_dry_r,
    input  logic signed [15:0] chip_b_wet_l,
    input  logic signed [15:0] chip_b_wet_r,
    input  logic        [ 6:0] volume,
    input  logic        [ 1:0] enable,
    input  logic               mute,
    output logic signed [15:0] pcm0_l,
    output logic signed [15:0] pcm0_r,
    output logic signed [15:0] pcm1_l,
    output logic signed [15:0] pcm1_r,
    output logic               pair_valid,
    output logic        [15:0] pair_epoch
);
    // One latest snapshot per chip. A missing/mismatched epoch holds the last
    // coherent pair; no sample, timer or native clock is gated. Tags identify
    // native frame epochs, not the number of successful output handoffs.
    // Equality assumes no mailbox survives a full 65536-frame tag wrap.
    logic [63:0] words_a_q, words_b_q, words_a_d, words_b_d;
    logic [15:0] epoch_a_q, epoch_b_q, epoch_a_d, epoch_b_d;
    logic pending_a_q, pending_b_q, pending_a_d, pending_b_d;
    logic commit_pair;
    logic [15:0] commit_epoch;
    logic snapshot_ok_a_q, snapshot_ok_b_q, snapshot_ok_a_d, snapshot_ok_b_d;
    logic coherent_ok_a_q, coherent_ok_b_q, product_ok_a_q, product_ok_b_q;
    logic pair_loaded_q;
    logic [15:0] loaded_epoch_q;
    logic signed [16:0] a_l, a_r, b_l, b_r;
    logic signed [16:0] sum_a_l_q, sum_a_r_q, sum_b_l_q, sum_b_r_q;
    logic signed [32:0] product_a_l, product_a_r, product_b_l, product_b_r;
    logic signed [33:0] product_both_l, product_both_r;
    wire signed [32:0] product_a_l_next = sum_a_l_q * $signed(gain_r);
    wire signed [32:0] product_a_r_next = sum_a_r_q * $signed(gain_r);
    wire signed [32:0] product_b_l_next = sum_b_l_q * $signed(gain_r);
    wire signed [32:0] product_b_r_next = sum_b_r_q * $signed(gain_r);

    function automatic signed [16:0] sum_pair(
        input logic [63:0] words, input logic select_right
    );
        if (select_right)
            sum_pair = $signed({words[47], words[47:32]}) +
                       (WET_MIX ? $signed({words[15], words[15:0]}) : 17'sd0);
        else
            sum_pair = $signed({words[63], words[63:48]}) +
                       (WET_MIX ? $signed({words[31], words[31:16]}) : 17'sd0);
    endfunction

    always_comb begin
        words_a_d = words_a_q; words_b_d = words_b_q;
        epoch_a_d = epoch_a_q; epoch_b_d = epoch_b_q;
        pending_a_d = pending_a_q; pending_b_d = pending_b_q;
        if (chip_a_valid) begin
            words_a_d = {chip_a_dry_l, chip_a_dry_r, chip_a_wet_l, chip_a_wet_r};
            epoch_a_d = chip_a_epoch;
            pending_a_d = 1'b1;
        end
        if (chip_b_valid) begin
            words_b_d = {chip_b_dry_l, chip_b_dry_r, chip_b_wet_l, chip_b_wet_r};
            epoch_b_d = chip_b_epoch;
            pending_b_d = 1'b1;
        end
        // A disabled chip contributes zero; the other chip can keep retiring
        // native loads even if the disabled chip has a sample-ROM wait.
        commit_epoch = epoch_a_d;
        if (!chip_a_enabled && chip_b_enabled) begin
            commit_pair = pending_b_d;
            commit_epoch = epoch_b_d;
        end else if (chip_a_enabled && !chip_b_enabled) begin
            commit_pair = pending_a_d;
        end else begin
            commit_pair = pending_a_d && pending_b_d && (epoch_a_d == epoch_b_d);
        end
        snapshot_ok_a_d = chip_a_enabled && (chip_a_valid || snapshot_ok_a_q);
        snapshot_ok_b_d = chip_b_enabled && (chip_b_valid || snapshot_ok_b_q);
        // Preserve the existing board speaker swap before speaker controls.
        a_l = sum_pair(words_a_d, 1'b1); b_l = sum_pair(words_b_d, 1'b1);
        a_r = sum_pair(words_a_d, 1'b0);  b_r = sum_pair(words_b_d, 1'b0);
        if (commit_pair) begin
            pending_a_d = 1'b0;
            pending_b_d = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            words_a_q <= 64'd0; words_b_q <= 64'd0;
            epoch_a_q <= 16'd0; epoch_b_q <= 16'd0;
            pending_a_q <= 1'b0; pending_b_q <= 1'b0;
            sum_a_l_q <= 17'sd0; sum_a_r_q <= 17'sd0;
            sum_b_l_q <= 17'sd0; sum_b_r_q <= 17'sd0;
            product_a_l <= 33'sd0; product_a_r <= 33'sd0;
            product_b_l <= 33'sd0; product_b_r <= 33'sd0;
            product_both_l <= 34'sd0; product_both_r <= 34'sd0;
            pair_loaded_q <= 1'b0;
            loaded_epoch_q <= 16'd0;
            pair_valid <= 1'b0;
            pair_epoch <= 16'd0;
        end else begin
            words_a_q <= words_a_d; words_b_q <= words_b_d;
            epoch_a_q <= epoch_a_d; epoch_b_q <= epoch_b_d;
            pending_a_q <= pending_a_d; pending_b_q <= pending_b_d;
            // One additional host clock isolates the DSP from the limiting
            // and balanced-lane logic. Volume lookup + product is two clocks;
            // the shared legacy gain API keeps its original one-clock lookup.
            product_a_l <= product_a_l_next;
            product_a_r <= product_a_r_next;
            product_b_l <= product_b_l_next;
            product_b_r <= product_b_r_next;
            // Capture the full sum at the same age as the individual products.
            // Live D0 exclusion then selects a registered candidate without a
            // wide adder between the CPU write guard and the legacy RC filter.
            product_both_l <= $signed({product_a_l_next[32], product_a_l_next}) +
                              $signed({product_b_l_next[32], product_b_l_next});
            product_both_r <= $signed({product_a_r_next[32], product_a_r_next}) +
                              $signed({product_b_r_next[32], product_b_r_next});
            pair_loaded_q <= commit_pair;
            pair_valid <= pair_loaded_q;
            if (pair_loaded_q) pair_epoch <= loaded_epoch_q;
            if (commit_pair) begin
                sum_a_l_q <= chip_a_enabled ? a_l : 17'sd0;
                sum_a_r_q <= chip_a_enabled ? a_r : 17'sd0;
                sum_b_l_q <= chip_b_enabled ? b_l : 17'sd0;
                sum_b_r_q <= chip_b_enabled ? b_r : 17'sd0;
                loaded_epoch_q <= commit_epoch;
            end
        end
    end

    // D0 asynchronously clears the physical serializers. Forget eligibility
    // at every stage, including a pending pre-mute snapshot, so raising D0
    // cannot resurrect an old word before a fresh enabled native load.
    // Combine reset sources into one active-high asynchronous clear so the
    // same sub-host-clock mute behavior infers a native FPGA reset primitive.
    wire eligibility_rst_a = rst || !chip_a_enabled;
    wire eligibility_rst_b = rst || !chip_b_enabled;
    always_ff @(posedge clk or posedge eligibility_rst_a) begin
        if (eligibility_rst_a) begin
            snapshot_ok_a_q <= 1'b0;
            coherent_ok_a_q <= 1'b0;
            product_ok_a_q <= 1'b0;
        end else begin
            snapshot_ok_a_q <= snapshot_ok_a_d;
            if (commit_pair) coherent_ok_a_q <= snapshot_ok_a_d;
            product_ok_a_q <= coherent_ok_a_q;
        end
    end
    always_ff @(posedge clk or posedge eligibility_rst_b) begin
        if (eligibility_rst_b) begin
            snapshot_ok_b_q <= 1'b0;
            coherent_ok_b_q <= 1'b0;
            product_ok_b_q <= 1'b0;
        end else begin
            snapshot_ok_b_q <= snapshot_ok_b_d;
            if (commit_pair) coherent_ok_b_q <= snapshot_ok_b_d;
            product_ok_b_q <= coherent_ok_b_q;
        end
    end

    logic [15:0] gain_r;
    logic signed [33:0] product_l, product_r, scaled_l, scaled_r;
    logic signed [16:0] limited_l, limited_r, half_l, half_r, rest_l, rest_r;
    jtviostorm_k054321_curve u_curve(.clk(clk), .volume(volume), .gain(gain_r));

    always_comb begin
        // All candidates remain unshifted/unclipped. Select by live eligibility
        // so D0 still excludes a chip immediately and cannot revive stale data.
        case ({chip_b_enabled && product_ok_b_q,
               chip_a_enabled && product_ok_a_q})
            2'b11: begin product_l = product_both_l; product_r = product_both_r; end
            2'b01: begin
                product_l = $signed({product_a_l[32], product_a_l});
                product_r = $signed({product_a_r[32], product_a_r});
            end
            2'b10: begin
                product_l = $signed({product_b_l[32], product_b_l});
                product_r = $signed({product_b_r[32], product_b_r});
            end
            default: begin product_l = 34'sd0; product_r = 34'sd0; end
        endcase
        // Apply output normalization before the single board clip. Changing
        // the final fractional-bit selection avoids an earlier narrow shift
        // that could wrap loud signals or discard quiet sample bits.
        scaled_l = product_l >>> (12-OUTPUT_GAIN_SHIFT);
        scaled_r = product_r >>> (12-OUTPUT_GAIN_SHIFT);
        if (rst || mute || !enable[1]) limited_l = 17'sd0;
        else if (scaled_l > 34'sd65534) limited_l = 17'sd65534;
        else if (scaled_l < -34'sd65536) limited_l = 17'sh10000;
        else limited_l = scaled_l[16:0];
        if (rst || mute || !enable[0]) limited_r = 17'sd0;
        else if (scaled_r > 34'sd65534) limited_r = 17'sd65534;
        else if (scaled_r < -34'sd65536) limited_r = 17'sh10000;
        else limited_r = scaled_r[16:0];
        // Two equal unity-gain legacy RC lanes encode the completed board sum.
        // Keep the remainder on lane1 so odd negative/positive codes are exact.
        half_l = limited_l >>> 1; rest_l = limited_l - half_l;
        half_r = limited_r >>> 1; rest_r = limited_r - half_r;
        pcm0_l = half_l[15:0]; pcm1_l = rest_l[15:0];
        pcm0_r = half_r[15:0]; pcm1_r = rest_r[15:0];
    end
endmodule

// One authoritative registered lookup shared by the wide board adapter and
// the legacy jtviostorm_k054321_gain API. Constants/latency are unchanged.
module jtviostorm_k054321_curve(
    input  logic        clk,
    input  logic [ 6:0] volume,
    output logic [15:0] gain
);
    function automatic [15:0] gain_q12(input logic [6:0] v);
        begin
            case (v)
                7'd0:  gain_q12 = 16'd256;
                7'd1:  gain_q12 = 16'd274;
                7'd2:  gain_q12 = 16'd294;
                7'd3:  gain_q12 = 16'd315;
                7'd4:  gain_q12 = 16'd338;
                7'd5:  gain_q12 = 16'd362;
                7'd6:  gain_q12 = 16'd388;
                7'd7:  gain_q12 = 16'd416;
                7'd8:  gain_q12 = 16'd446;
                7'd9:  gain_q12 = 16'd478;
                7'd10: gain_q12 = 16'd512;
                7'd11: gain_q12 = 16'd549;
                7'd12: gain_q12 = 16'd588;
                7'd13: gain_q12 = 16'd630;
                7'd14: gain_q12 = 16'd676;
                7'd15: gain_q12 = 16'd724;
                7'd16: gain_q12 = 16'd776;
                7'd17: gain_q12 = 16'd832;
                7'd18: gain_q12 = 16'd891;
                7'd19: gain_q12 = 16'd955;
                7'd20: gain_q12 = 16'd1024;
                7'd21: gain_q12 = 16'd1097;
                7'd22: gain_q12 = 16'd1176;
                7'd23: gain_q12 = 16'd1261;
                7'd24: gain_q12 = 16'd1351;
                7'd25: gain_q12 = 16'd1448;
                7'd26: gain_q12 = 16'd1552;
                7'd27: gain_q12 = 16'd1663;
                7'd28: gain_q12 = 16'd1783;
                7'd29: gain_q12 = 16'd1911;
                7'd30: gain_q12 = 16'd2048;
                7'd31: gain_q12 = 16'd2195;
                7'd32: gain_q12 = 16'd2353;
                7'd33: gain_q12 = 16'd2521;
                7'd34: gain_q12 = 16'd2702;
                7'd35: gain_q12 = 16'd2896;
                7'd36: gain_q12 = 16'd3104;
                7'd37: gain_q12 = 16'd3327;
                7'd38: gain_q12 = 16'd3566;
                7'd39: gain_q12 = 16'd3822;
                7'd40: gain_q12 = 16'd4096;
                7'd41: gain_q12 = 16'd4390;
                7'd42: gain_q12 = 16'd4705;
                7'd43: gain_q12 = 16'd5043;
                7'd44: gain_q12 = 16'd5405;
                7'd45: gain_q12 = 16'd5793;
                7'd46: gain_q12 = 16'd6208;
                7'd47: gain_q12 = 16'd6654;
                7'd48: gain_q12 = 16'd7132;
                7'd49: gain_q12 = 16'd7643;
                7'd50: gain_q12 = 16'd8192;
                7'd51: gain_q12 = 16'd8780;
                7'd52: gain_q12 = 16'd9410;
                7'd53: gain_q12 = 16'd10086;
                7'd54: gain_q12 = 16'd10809;
                7'd55: gain_q12 = 16'd11585;
                7'd56: gain_q12 = 16'd12417;
                7'd57: gain_q12 = 16'd13308;
                7'd58: gain_q12 = 16'd14263;
                7'd59: gain_q12 = 16'd15287;
                7'd60: gain_q12 = 16'd16384;
                7'd61: gain_q12 = 16'd17560;
                7'd62: gain_q12 = 16'd18820;
                7'd63: gain_q12 = 16'd20171;
                default: gain_q12 = 16'd21619;
            endcase
        end
    endfunction
    always_ff @(posedge clk) gain <= gain_q12(volume);
endmodule
