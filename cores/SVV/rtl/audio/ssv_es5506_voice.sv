// SPDX-License-Identifier: GPL-3.0-or-later
// Ensoniq ES5506 voice scheduler / PCM / filter / mixer.
// OTTO Spec Rev. 2.3 + MAME es5506.cpp behavioral cross-check.
// See docs/ES5506_RESEARCH.md.
`timescale 1ns/1ps

module ssv_es5506_voice (
    // Per-game configuration: ES5506 bank population and aliasing.
    input  ssv_pkg::ssv_cfg_t cfg,
    input  logic        srmp7_bank,
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,

    input  logic [4:0]  active_voices,

    output logic [4:0]  eng_voice,
    input  logic [15:0] eng_cr,
    input  logic        eng_cr_valid,
    input  logic [16:0] eng_fc,
    input  logic [15:0] eng_lvol,
    input  logic [7:0]  eng_lvramp,
    input  logic [15:0] eng_rvol,
    input  logic [7:0]  eng_rvramp,
    input  logic [8:0]  eng_ecount,
    input  logic [15:0] eng_k1,
    input  logic [8:0]  eng_k1ramp,
    input  logic [15:0] eng_k2,
    input  logic [8:0]  eng_k2ramp,
    input  logic [31:0] eng_start,
    input  logic [31:0] eng_end,
    input  logic [31:0] eng_accum,
    input  logic [17:0] eng_o4n1,
    input  logic [17:0] eng_o3n1,
    input  logic [17:0] eng_o3n2,
    input  logic [17:0] eng_o2n1,
    input  logic [17:0] eng_o2n2,
    input  logic [17:0] eng_o1n1,

    output logic        eng_wr_accum,
    output logic [31:0] eng_accum_w,
    output logic        eng_wr_cr,
    // CR writeback as set/clear masks over the live register, not a value.
    // The engine's end-of-sample transition is the chip's own read-modify-
    // write of STOP0/IRQ/DIR/LPE/BLE/LEI: shipping the whole snapshot-derived
    // word let a concurrent host CR write and the writeback clobber each
    // other whichever way the register file arbitrated it. Masks compose:
    // the host keeps every bit the engine doesn't touch, and the engine's
    // one-shot transitions (STOP at end, BLE->LEI promotion) always land.
    // Dropping them was the audible bug: a lost BLE transition leaves the
    // loop bits armed forever (sound repeats long after its trigger) or
    // leaves LEI set with an unwrapped accumulator (runs off the end of the
    // sample bank -- the warped/garbled layer).
    output logic [15:0] eng_cr_set,
    output logic [15:0] eng_cr_clr,
    output logic        eng_wr_filt,
    output logic [17:0] eng_o4n1_w,
    output logic [17:0] eng_o3n1_w,
    output logic [17:0] eng_o3n2_w,
    output logic [17:0] eng_o2n1_w,
    output logic [17:0] eng_o2n2_w,
    output logic [17:0] eng_o1n1_w,
    output logic        eng_wr_env,
    output logic [15:0] eng_lvol_w,
    output logic [15:0] eng_rvol_w,
    output logic [15:0] eng_k1_w,
    output logic [15:0] eng_k2_w,
    output logic [8:0]  eng_ecount_w,
    // IRQV is available when its active-low vector output is inactive.
    // A voice with CR.IRQ set retries on each scan until this is true.
    input  logic        irq_ready,
    output logic        eng_irq_set,
    output logic [4:0]  eng_irq_voice,

    // An ECOUNT host write restarts that voice's slow filter-ramp cadence.
    input  logic        host_ecount_write,
    input  logic [4:0]  host_ecount_voice,

    output logic        sdr_req,
    output logic [ssv_pkg::SDR_AW:1] sdr_addr,
    input  logic [15:0] sdr_dout,
    input  logic        sdr_ack,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        sample_tick,
    output logic        underrun,

    // Pulses for exactly the cycle this voice's registers are snapshotted
    // from the register file (S_START). Lets the register file clear its
    // "host wrote a fresher value since this voice's snapshot" tracking at
    // the one instant that tracking is known correct -- see
    // docs/debug/ES5506_WARPED_NOTES_ROOT_CAUSE_20260819.md.
    output logic        eng_snap,
    // From the register file: the shared MLAB read port carries this
    // voice's clean data (no host read-steal/hold in flight, no commit to
    // this voice settling). S_START waits for it before snapshotting --
    // hardware-proven necessity (2026-08-27 WB capture: a snapshot taken
    // inside a steal window consumed a foreign ACCUM and teleported the
    // voice; the audible random warped-sound defect).
    input  logic        snap_ok
);

import ssv_pkg::*;

function automatic logic [SDR_AW:1] sample_address(
    input ssv_cfg_t cfg_in,
    input logic [1:0] bank,
    input logic [31:0] accum_in
);
    begin
        sample_address = sample_word_addr_cfg(
            cfg_in, bank, accum_in, srmp7_bank);
    end
endfunction

localparam logic [15:0] CR_STOP = 16'h0003;
localparam logic [15:0] CR_DIR  = 16'h0040;
localparam logic [15:0] CR_IRQE = 16'h0020;
localparam logic [15:0] CR_IRQ  = 16'h0080;
localparam logic [15:0] CR_BLE  = 16'h0010;
localparam logic [15:0] CR_LPE  = 16'h0008;
localparam logic [15:0] CR_LEI  = 16'h0004;
localparam logic [15:0] CR_CMPD = 16'h2000;

typedef enum logic [3:0] {
    S_START, S_WAIT1, S_REQ2, S_WAIT2,
    S_PROC, S_POLE12, S_FILT, S_MIX, S_NEXT
} st_t;

st_t state;
logic [4:0] voice_i;
// Fixed voice slot.
//
// The ES5506 gives every voice exactly 16 clocks, so the output sample rate is
// clk / (16 * active voices) and is completely independent of what the voice is
// doing. This engine instead emitted a sample whenever the last voice's state
// machine happened to finish -- nine states minimum, plus however long the
// sample fetch took -- so the rate moved with voice count AND with SDRAM
// latency. Sound effects (few voices) sounded right while music (many voices)
// played at the wrong pitch and drifted as instruments entered and left.
//
// slot_cnt paces each voice to the full 16 ticks regardless of how early its
// work finishes.
localparam int SLOT_TICKS = 16;
logic [4:0] slot_cnt;
logic [3:0] filtcount [0:31];
// 32-bit headroom: up to 32 voices each contributing up to the full 20-bit
// channel-accumulator range (spec section 6/12) sums to ~2^24.7, and this
// must never wrap before the end-of-scan saturating clamp -- a wrapped sum
// is indistinguishable from a much quieter signal, silently wrong rather
// than loudly clipped.
logic signed [31:0] mix_l, mix_r;
logic signed [15:0] s1, s2;
logic        got_ack;
logic [7:0]  wait_cnt;
logic [15:0] cr;
logic        cr_valid;
logic [16:0] fc;
logic [15:0] lvol, rvol, k1, k2;
logic [7:0]  lvramp, rvramp;
logic [8:0]  ecount, k1ramp, k2ramp;
logic [31:0] vstart, vend, accum;
logic [17:0] o4n1, o3n1, o3n2, o2n1, o2n2, o1n1;
// Pipeline: lerp/loop → poles 1-2 → poles 3-4 → volume/mix (timing).
logic        proc_active;
logic [31:0] proc_accn;
logic [15:0] proc_crn;
logic signed [17:0] proc_xin;
logic [17:0] proc_p1, proc_p2, proc_p3, proc_p4;

wire stopped = !cr_valid || |(cr & CR_STOP);

// OTTO Spec Rev 2.3 section 11.6 (p36): the 16-bit filter-4 output is
// multiplied by 1MMMMMMMM (M = the 8 mantissa bits), the top 20 bits of that
// 25-bit product are kept, then right-shifted by (15 - exponent). Net:
// (s16 * {1,mantissa}) >> (20 - exponent). This replaces a two-step form
// that rounded the gain to an integer before the sample multiply (silently
// zeroing the contribution for low exponents) and then additionally shifted
// by >>>13 instead of the spec's per-exponent (20-e) -- a fixed 2-bit-too-
// much attenuation on top of an already-wrong per-exponent shift, so a
// single max-volume voice was clipping the 16-bit output by 4x before any
// other voice was summed in. See docs/ES5506_DATASHEET_AUDIT.md section A.
function automatic logic signed [31:0] vol_contrib(
    input logic signed [17:0] s18,
    input logic [15:0]        vol
);
    logic [3:0]  e;
    logic [8:0]  m;
    logic signed [31:0] p;
    integer shamt;
    begin
        e = vol[15:12];
        m = {1'b1, vol[11:4]};
        // s18 is filter-4's 18-bit result; [17:2] is the spec's 16-bit
        // panning-stage input (section 11.4, p32).
        p = $signed(s18[17:2]) * $signed({1'b0, m});
        shamt = 20 - {28'd0, e};
        vol_contrib = p >>> shamt;
    end
endfunction

function automatic logic signed [17:0] sat18(input logic signed [31:0] v);
    if (v > 32'sh0001_ffff) return 18'sh1ffff;
    if (v < -32'sh0002_0000) return -18'sh20000;
    return v[17:0];
endfunction

function automatic logic signed [17:0] lp(
    input logic signed [17:0] x,
    input logic [15:0] k,
    input logic signed [17:0] h
);
    // x and h are already 18-bit signed at their natural width. The previous
    // form re-sign-extended each to 32 bits before subtracting, which forced
    // Quartus to synthesize the downstream multiply against a 32-bit operand
    // (measured: doubled to two physical DSP blocks, "18x18 plus 36" plus a
    // companion "Two Independent 18x18", instead of one). Two 18-bit signed
    // values subtracted need at most 19 bits to represent the exact result
    // without overflow (range +-262142, fits in signed 19-bit's +-262144) --
    // `diff` below is numerically identical to the old 32-bit-wide
    // subtraction, just without the redundant high sign-extension bits that
    // don't change the value but do change how wide a multiplier Quartus
    // thinks it needs.
    logic signed [18:0] diff;
    logic signed [31:0] t;
    begin
        diff = $signed({x[17], x}) - $signed({h[17], h});
        t = ($signed(diff) * $signed({1'b0, k[15:4]})) >>> 12;
        lp = sat18($signed(h) + t);
    end
endfunction

function automatic logic signed [17:0] hp(
    input logic signed [17:0] x,
    input logic [15:0] k,
    input logic signed [17:0] h,
    input logic signed [17:0] prev
);
    // Same fix as lp(): h is already signed 18-bit at its declared width, so
    // $signed(h) carries the identical value the old 32-bit re-extension did
    // -- multiplying against it directly instead of a 32-bit-padded copy lets
    // this collapse back to a single DSP block.
    logic signed [31:0] t;
    begin
        t = ($signed({1'b0, k[15:4]}) * $signed(h)) >>> 13;
        hp = sat18($signed(x) - $signed(prev) + t + ($signed(h) >>> 1));
    end
endfunction

function automatic logic signed [17:0] lerp(
    input logic signed [15:0] a,
    input logic signed [15:0] b,
    input logic [31:0] acc
);
    // The fraction is 9 bits by construction (acc[10:2]) -- OTTO Spec Rev 2.3
    // section 11.3 (p32): "ACCfr is the 9 fractional bits of the
    // Accumulator". The accumulator's fractional field is 11 bits (it also
    // sets frequency resolution) but only the top 9 feed interpolation; 9 is
    // correct here and MAME's 11-bit fraction is the deviation, not this.
    //
    // Section 11.3 also states: "The output of the Interpolator is
    // maintained at 18-bits when sent to the filters." Taking t[24:9]
    // rounded the interpolated result to 16-bit resolution before it ever
    // reached the 18-bit filter datapath, discarding two low bits of
    // precision on every sample of every voice for the life of the filter
    // cascade. Taking t[24:7] keeps the same integer scale (the *512
    // weighting is unchanged) while retaining those two bits. See
    // docs/ES5506_DATASHEET_AUDIT.md section C.
    logic [8:0] frac;
    logic signed [31:0] t;
    begin
        frac = acc[10:2];
        t = $signed(a) * (32'sd512 - 32'(frac)) + $signed(b) * 32'(frac);
        lerp = t[24:7];
    end
endfunction

assign eng_voice = voice_i;
// `state` holds S_START across every clk cycle until the next `ce` edge
// consumes it (S_START never self-loops), and ce is a sparse ~16 MHz
// enable -- so "state==S_START" alone can stay high for several clk
// cycles. Gate on ce too: the snapshot only actually latches (cr <= ...
// etc., in the S_START case below) on the one edge where both are true.
assign eng_snap  = ce && (state == S_START) && snap_ok;

// Sample SDRAM handshake is independent of ce_snd. Production ce_snd is a
// sparse ~16 MHz enable; acks arrive on clk_sys and must not be dropped.
always_ff @(posedge clk) begin
    if (rst) begin
        state <= S_START;
        voice_i <= '0;
        slot_cnt <= 5'd0;
        sdr_req <= 1'b0;
        sdr_addr <= '0;
        got_ack <= 1'b0;
        mix_l <= '0;
        mix_r <= '0;
        audio_l <= '0;
        audio_r <= '0;
        sample_tick <= 1'b0;
        underrun <= 1'b0;
        wait_cnt <= 8'd0;
        eng_wr_accum <= 1'b0;
        eng_wr_cr <= 1'b0;
        eng_wr_filt <= 1'b0;
        eng_wr_env <= 1'b0;
        eng_irq_set <= 1'b0;
        eng_accum_w <= '0;
        eng_cr_set <= '0;
        eng_cr_clr <= '0;
        eng_o4n1_w <= '0;
        eng_o3n1_w <= '0;
        eng_o3n2_w <= '0;
        eng_o2n1_w <= '0;
        eng_o2n2_w <= '0;
        eng_o1n1_w <= '0;
        eng_lvol_w <= '0;
        eng_rvol_w <= '0;
        eng_k1_w <= '0;
        eng_k2_w <= '0;
        eng_ecount_w <= '0;
        eng_irq_voice <= '0;
        proc_active <= 1'b0;
        proc_accn <= '0;
        proc_crn <= '0;
        proc_xin <= '0;
        proc_p1 <= '0;
        proc_p2 <= '0;
        proc_p3 <= '0;
        proc_p4 <= '0;
        for (int i = 0; i < 32; i++) filtcount[i] <= '0;
    end else begin
        sample_tick <= 1'b0;
        eng_wr_accum <= 1'b0;
        eng_wr_cr <= 1'b0;
        eng_wr_filt <= 1'b0;
        eng_wr_env <= 1'b0;
        eng_irq_set <= 1'b0;

        // Capture SDRAM data whenever ack pulses, even if ce is low.
        if (sdr_ack && sdr_req) begin
            sdr_req <= 1'b0;
            if (state == S_WAIT1 && !got_ack) begin
                s1 <= sdr_dout;
                got_ack <= 1'b1;
                wait_cnt <= 8'd0;
            end else if (state == S_WAIT2 && !got_ack) begin
                s2 <= sdr_dout;
                got_ack <= 1'b1;
                wait_cnt <= 8'd0;
            end
        end else if ((state == S_WAIT1 || state == S_WAIT2) && !got_ack) begin
            // Sample deadline miss: SDRAM did not return S1/S2 in time.
            if (wait_cnt == 8'hff)
                underrun <= 1'b1;
            else
                wait_cnt <= wait_cnt + 8'd1;
        end else begin
            wait_cnt <= 8'd0;
        end

        if (ce) begin
            if (slot_cnt != SLOT_TICKS[4:0] - 5'd1) slot_cnt <= slot_cnt + 5'd1;

        unique case (state)
                S_START: if (!snap_ok) begin
                    // Register-file read port busy (host steal/hold, or a
                    // commit to this voice still settling): wait. The slot
                    // pacing in S_NEXT absorbs the delay -- a read occupies
                    // four clocks against ~7 spare ce ticks per slot.
                    state <= S_START;
                end else begin
                    cr       <= eng_cr_valid ? eng_cr : 16'h0003;
                    cr_valid <= eng_cr_valid;
                    fc       <= eng_fc;
                    lvol     <= eng_lvol;
                    rvol     <= eng_rvol;
                    lvramp   <= eng_lvramp;
                    rvramp   <= eng_rvramp;
                    ecount   <= eng_ecount;
                    k1       <= eng_k1;
                    k2       <= eng_k2;
                    k1ramp   <= eng_k1ramp;
                    k2ramp   <= eng_k2ramp;
                    vstart   <= eng_start;
                    vend     <= eng_end;
                    accum    <= eng_accum;
                    o4n1     <= eng_o4n1;
                    o3n1     <= eng_o3n1;
                    o3n2     <= eng_o3n2;
                    o2n1     <= eng_o2n1;
                    o2n2     <= eng_o2n2;
                    o1n1     <= eng_o1n1;
                    if (!eng_cr_valid ||
                        |((eng_cr_valid ? eng_cr : 16'h0003) & CR_STOP) ||
                        (eng_cr_valid && (eng_start == eng_end))) begin
                        s1 <= '0;
                        s2 <= '0;
                        state <= S_PROC;
                    end else if (!cfg.bank_valid[
                                     (eng_cr_valid ? eng_cr[15:14] : 2'b00)
                                 ]) begin
                        // The voice selects an ES5506 bank this cartridge does
                        // not populate. Dyna Gear populates bank 2 only, which
                        // is what the old hardwired `!= 2'b10` encoded; other
                        // SSV titles populate 0/1 and alias 2/3 onto them via
                        // MAME ROM_COPY, so the valid set is per game.
                        s1 <= '0;
                        s2 <= '0;
                        state <= S_PROC;
                    end else begin
                        // Word offset is 21 bits; pad to [SDR_AW:1] without a wider sum.
                        // bank_map selects which loaded sample slot this CR bank
                        // reads from, which is how ROM_COPY aliases are honoured
                        // without duplicating the data in SDRAM.
                        sdr_addr <= sample_address(
                            cfg, eng_cr[15:14], eng_accum);
                        sdr_req  <= 1'b1;
                        got_ack  <= 1'b0;
                        state    <= S_WAIT1;
                    end
                end

                S_WAIT1: if (got_ack) begin
                    got_ack <= 1'b0;
                    state <= S_REQ2;
                end

                S_REQ2: begin
                    // Second interpolation tap. MAME's get_integer_addr(accum,
                    // 1) adds the +1 to the accumulator's integer field BEFORE
                    // the 21-bit mask, so at the last word of a bank the tap
                    // wraps to word 0 of the SAME bank. Adding 1 to the fully
                    // formed SDRAM address instead escaped into the next 4 MiB
                    // slot (or past the sample area entirely for the last
                    // slot). Wrap the integer field first, as MAME does.
                    sdr_addr <= sample_address(cfg, cr[15:14],
                                               {accum[31:11] + 21'd1, 11'd0});
                    sdr_req  <= 1'b1;
                    got_ack  <= 1'b0;
                    state    <= S_WAIT2;
                end

                S_WAIT2: if (got_ack) begin
                    got_ack <= 1'b0;
                    state <= S_PROC;
                end

                S_PROC: begin
                    // Stage 1: lerp + accumulator/loop/IRQ only (filter
                    // poles are computed in S_POLE12/S_FILT unconditionally
                    // -- see the note there).
                    proc_active <= 1'b0;
                    proc_accn <= accum;
                    proc_crn <= cr;
                    // Stopped/degenerate voices feed zero into the filter
                    // chain instead of the old x=h trick (which forced
                    // lp()/hp() to compute a zero delta and freeze the pole
                    // state exactly where it was). Spec section 5 (p14):
                    // filter temp registers "are continuously updated even
                    // when the voice is stopped" -- the voice-setup
                    // procedure (section 8, p21) writes K1=K2=FFFh and
                    // relies on live poles draining stale state within four
                    // sample periods before the next note starts. A frozen
                    // chain never drains, so every retrigger played through
                    // the previous note's leftover filter tail. See
                    // docs/ES5506_DATASHEET_AUDIT.md section B.
                    proc_xin <= 18'sd0;
                    proc_p1 <= o1n1;
                    proc_p2 <= o2n1;
                    proc_p3 <= o3n1;
                    proc_p4 <= o4n1;

                    if (cr_valid && !(cr & CR_STOP) && (vstart == vend)) begin
                        // A degenerate range stops before any sample fetch or
                        // output.  S_START bypassed SDRAM for this case.
                        proc_crn <= cr | 16'h0001;
                    end else if (!stopped) begin
                        logic signed [17:0] ip;
                        logic [31:0] accn;
                        logic [15:0] crn;

                        ip  = (cr & CR_CMPD)
                            ? lerp(es5506_ulaw_decode(s1[15:8]),
                                   es5506_ulaw_decode(s2[15:8]), accum)
                            : lerp(s1, s2, accum);
                        accn = (cr & CR_DIR) ? (accum - {15'd0, fc})
                                             : (accum + {15'd0, fc});
                        crn = cr;

                        if (!(cr & CR_DIR) && (accn > vend) && !(cr & CR_LEI)) begin
                            if (cr & CR_IRQE) crn = crn | CR_IRQ;
                            unique case (cr & (CR_LPE|CR_BLE))
                                16'h0000: crn = crn | 16'h0001;
                                CR_LPE: accn = vstart + (accn - vend);
                                CR_BLE: begin
                                    accn = vstart + (accn - vend);
                                    crn = (crn & ~(CR_LPE | CR_BLE)) | CR_LEI;
                                end
                                default: begin
                                    accn = vend - (accn - vend);
                                    crn = crn ^ CR_DIR;
                                end
                            endcase
                        end else if ((cr & CR_DIR) && (accn < vstart) && !(cr & CR_LEI)) begin
                            if (cr & CR_IRQE) crn = crn | CR_IRQ;
                            unique case (cr & (CR_LPE|CR_BLE))
                                16'h0000: crn = crn | 16'h0001;
                                CR_LPE: accn = vend - (vstart - accn);
                                CR_BLE: begin
                                    accn = vend - (vstart - accn);
                                    crn = (crn & ~(CR_LPE | CR_BLE)) | CR_LEI;
                                end
                                default: begin
                                    accn = vstart + (vstart - accn);
                                    crn = crn ^ CR_DIR;
                                end
                            endcase
                        end

                        proc_active <= 1'b1;
                        proc_accn <= accn;
                        proc_crn <= crn;
                        proc_xin <= ip;
                    end
                    state <= S_POLE12;
                end

                S_POLE12: begin
                    // Stage 2: first two filter poles. Runs for every voice
                    // every slot, active or stopped -- see the S_PROC note
                    // on proc_xin. proc_active still gates whether the
                    // result is allowed to contribute to the mix and
                    // whether ACCUM/CR advance; it no longer gates whether
                    // the filter state itself moves.
                    begin
                        logic signed [17:0] p1, p2;
                        p1 = lp(proc_xin, k1, o1n1);
                        p2 = lp(p1, k1, o2n1);
                        proc_p1 <= p1;
                        proc_p2 <= p2;
                    end
                    state <= S_FILT;
                end

                S_FILT: begin
                    // Stage 3: remaining filter poles (mode-dependent).
                    // Unconditional -- see S_POLE12.
                    begin
                        logic signed [17:0] p3, p4;
                        unique case (cr[9:8])
                            2'b00: begin
                                // prev must be this pole's INPUT one
                                // sample ago (pole 2's output), not two.
                                p3 = hp(proc_p2, k2, o3n1, o2n1);
                                p4 = hp(p3, k2, o4n1, o3n1);
                            end
                            2'b01: begin
                                p3 = lp(proc_p2, k1, o3n1);
                                p4 = hp(p3, k2, o4n1, o3n1);
                            end
                            2'b10: begin
                                p3 = lp(proc_p2, k2, o3n1);
                                p4 = lp(p3, k2, o4n1);
                            end
                            default: begin
                                p3 = lp(proc_p2, k1, o3n1);
                                p4 = lp(p3, k2, o4n1);
                            end
                        endcase
                        proc_p3 <= p3;
                        proc_p4 <= p4;
                    end
                    state <= S_MIX;
                end

                S_MIX: begin
                    // Stage 4: volume, mix accumulate, register writebacks.
                    eng_accum_w <= accum;
                    eng_cr_set <= '0;
                    eng_cr_clr <= '0;
                    eng_o1n1_w <= o1n1;
                    eng_o2n1_w <= o2n1;
                    eng_o2n2_w <= o2n2;
                    eng_o3n1_w <= o3n1;
                    eng_o3n2_w <= o3n2;
                    eng_o4n1_w <= o4n1;
                    eng_lvol_w <= lvol;
                    eng_rvol_w <= rvol;
                    eng_k1_w <= k1;
                    eng_k2_w <= k2;
                    eng_ecount_w <= ecount;

                    // Filter temps are written back for every voice, stopped
                    // or not -- S_POLE12/S_FILT now compute them
                    // unconditionally (fed with zero input while stopped),
                    // and the writeback must follow or the drain in B has
                    // nowhere to land. See docs/ES5506_DATASHEET_AUDIT.md
                    // section B.
                    eng_wr_filt <= 1'b1;
                    eng_o1n1_w  <= proc_p1;
                    eng_o2n2_w  <= o2n1;
                    eng_o2n1_w  <= proc_p2;
                    eng_o3n2_w  <= o3n1;
                    eng_o3n1_w  <= proc_p3;
                    eng_o4n1_w  <= proc_p4;

                    if (proc_active) begin
                        // Section A: (s16 * {1,mantissa}) >> (20-exponent)
                        // per voice, summed into a wide accumulator and
                        // saturated to the chip's 20-bit channel rail once,
                        // at end of scan (S_NEXT) -- not attenuated per
                        // voice here.
                        mix_l <= mix_l + vol_contrib(proc_p4, lvol);
                        mix_r <= mix_r + vol_contrib(proc_p4, rvol);

                        eng_wr_accum <= 1'b1;
                        eng_accum_w  <= proc_accn;
                    end

                    // CR.IRQ is a per-voice pending bit.  Leave it set while
                    // IRQV is occupied, then promote and clear it on a later
                    // scan after the host acknowledges the previous vector.
                    if ((proc_crn & CR_IRQ) && irq_ready) begin
                        eng_irq_set <= 1'b1;
                        eng_irq_voice <= voice_i;
                        eng_wr_cr <= 1'b1;
                        eng_cr_set <= (proc_crn & ~CR_IRQ) & ~cr;
                        eng_cr_clr <= cr & ~(proc_crn & ~CR_IRQ);
                    end else if (proc_crn != cr) begin
                        eng_wr_cr <= 1'b1;
                        eng_cr_set <= proc_crn & ~cr;
                        eng_cr_clr <= cr & ~proc_crn;
                    end

                    // FILTCOUNT free-runs every sample period regardless of
                    // ECOUNT (OTTO Spec Rev 2.3 section 11.5, p35: the
                    // "FILTCOUNT = FILTCOUNT + 1" step sits outside the
                    // "if ECOUNT != 0" guard). Previously it only advanced
                    // while an envelope was active, so its divide-by-eight
                    // phase for slow K1/K2 ramps drifted after any envelope
                    // pause. See docs/ES5506_DATASHEET_AUDIT.md section D.
                    filtcount[voice_i] <= filtcount[voice_i] + 4'd1;

                    // Envelopes advance for stopped and running voices alike.
                    // Slow negative K ramps test the old counter, so the first
                    // step occurs at count zero, then eight, sixteen, ...
                    if (ecount != 9'd0) begin
                        logic signed [16:0] tmp;
                        eng_wr_env <= 1'b1;
                        eng_ecount_w <= ecount - 9'd1;
                        if (lvramp != 8'd0) begin
                            tmp = $signed({1'b0, lvol}) + $signed({{9{lvramp[7]}}, lvramp});
                            if (tmp < 0) eng_lvol_w <= 16'd0;
                            else if (tmp > 17'sh0ffff) eng_lvol_w <= 16'hffff;
                            else eng_lvol_w <= tmp[15:0];
                        end
                        if (rvramp != 8'd0) begin
                            tmp = $signed({1'b0, rvol}) + $signed({{9{rvramp[7]}}, rvramp});
                            if (tmp < 0) eng_rvol_w <= 16'd0;
                            else if (tmp > 17'sh0ffff) eng_rvol_w <= 16'hffff;
                            else eng_rvol_w <= tmp[15:0];
                        end
                        if (k1ramp[7:0] != 8'd0 &&
                            (!k1ramp[8] || filtcount[voice_i][2:0] == 3'd0)) begin
                            tmp = $signed({1'b0, k1}) + $signed({{9{k1ramp[7]}}, k1ramp[7:0]});
                            if (tmp < 0) eng_k1_w <= 16'd0;
                            else if (tmp > 17'sh0ffff) eng_k1_w <= 16'hffff;
                            else eng_k1_w <= tmp[15:0];
                        end
                        if (k2ramp[7:0] != 8'd0 &&
                            (!k2ramp[8] || filtcount[voice_i][2:0] == 3'd0)) begin
                            tmp = $signed({1'b0, k2}) + $signed({{9{k2ramp[7]}}, k2ramp[7:0]});
                            if (tmp < 0) eng_k2_w <= 16'd0;
                            else if (tmp > 17'sh0ffff) eng_k2_w <= 16'hffff;
                            else eng_k2_w <= tmp[15:0];
                        end
                    end
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    // Hold here until this voice has consumed its whole
                    // 16-tick slot. Everything below runs on the last tick, so
                    // the sample period is exactly 16 * (active_voices + 1)
                    // ticks whatever the fetch and filter took.
                    if (slot_cnt != SLOT_TICKS[4:0] - 5'd1) begin
                        state <= S_NEXT;
                    end
                    else begin
                    slot_cnt <= 5'd0;
                    if (voice_i == active_voices) begin
                        // Saturate to the chip's 20-bit channel-accumulator
                        // rail (spec section 6 p14 / section 12 p37: 23-bit
                        // register = 20 data bits + 3 overflow guard bits,
                        // saturated at transfer to serial output), then
                        // shift down to the 16-bit DAC word. The clamp
                        // bounds are exact multiples of 16, so the shift
                        // never needs its own separate saturate.
                        logic signed [31:0] cl, cr_;
                        cl  = (mix_l > 32'sh0007ffff) ? 32'sh0007ffff
                            : (mix_l < -32'sh00080000) ? -32'sh00080000 : mix_l;
                        cr_ = (mix_r > 32'sh0007ffff) ? 32'sh0007ffff
                            : (mix_r < -32'sh00080000) ? -32'sh00080000 : mix_r;
                        audio_l <= 16'(cl >>> 4);
                        audio_r <= 16'(cr_ >>> 4);
                        sample_tick <= 1'b1;
                        voice_i <= 5'd0;
                        mix_l <= '0;
                        mix_r <= '0;
                    end else
                        voice_i <= voice_i + 5'd1;
                    state <= S_START;
                    end
                end

                default: state <= S_START;
            endcase
        end

        // Host ECOUNT writes win over an envelope update on the same clock.
        if (host_ecount_write)
            filtcount[host_ecount_voice] <= 4'd0;
    end
end

endmodule
