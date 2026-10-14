// =============================================================================
// hc55516.sv -- Harris HC-55516 CVSD (Continuously Variable Slope Delta)
// decoder, as fitted to the Williams D-11581 / D-11581-20xx "Audio Board"
// (MAME 0.289 `s11c_bg_device`, src/mame/shared/s11c_bg.cpp).
//
// PROVENANCE / LICENCE
// -----------------------------------------------------------------------------
// This is an ORIGINAL SystemVerilog implementation written from the algorithm
// in MAME 0.289 `src/devices/sound/hc55516.cpp` (license:BSD-3-Clause,
// copyright-holders: Aaron Giles, Jonathan Gevaryahu, thanks-to: Zonn Moore).
// No HDL was copied from anywhere.
//
// Open-source HDL survey performed before writing (2026-08-13):
//   * jotego/jtcores -- searched for hc55516 / cvsd / 55516 / mc3417. jtcores
//     covers no Williams/Midway board that carries a CVSD decoder; there is no
//     CVSD module in that tree.
//   * MiSTer-devel -- the Williams-family cores (Arcade-Robotron, Arcade-Joust,
//     Arcade-Defender, Arcade-Sinistar, ...) and the Midway MCR cores that carry
//     a "Squawk & Talk"/CVSD path either omit the CVSD entirely or use a
//     board-specific ad-hoc decoder; no reusable, licence-clean HC55516 core was
//     found that matches MAME 0.289's corrected algorithm (the syllabic filter
//     constants and the `frozen` clamp below were rewritten in MAME in 2020 and
//     older third-party ports predate that).
// Conclusion recorded rather than assumed: nothing suitable existed to reuse,
// so this file is written from the MAME algorithm directly. It is BSD-3-Clause
// derived (algorithm only, no code), which is compatible with this project.
//
// ALGORITHM (hc55516.cpp, `hc55516_device` with the HC55516 constants
// sylmask=0xfc0, sylshift=6, syladd=0xfc1, intshift=4, shiftreg_mask=0x7,
// active clock edge = RISING)
// -----------------------------------------------------------------------------
// The decoder is a pure integer state machine; nothing here is an
// approximation. `process_bit(bit, clock_state)` runs on EVERY clock TRANSITION
// (both edges), not only the active one:
//
//   frozen = (intfilter >=  0x180 && !bit) ||
//            (intfilter <= -0x180 &&  bit);      // uses the RAW input bit,
//                                                 // before any /FZ substitution
//   if (rising edge) {
//       if (!/FZ) bit = ~shiftreg[0];            // /FZ active -> feed back
//       shiftreg = (shiftreg << 1) | bit;
//       coincidence = (shiftreg[2:0] == 0) || (shiftreg[2:0] == 7);
//       if (!frozen)
//           sylfilter += ((~sylfilter) & 0xfc0) >> 6
//                        + (coincidence ? 0 : 0xfc1);
//       sylfilter &= 0xfff;
//       sum = sext10( ((~intfilter) >> 4) + 1 );
//   } else {                                     // falling edge
//       mag = max(2, sylfilter >> 6);
//       sum = shiftreg[0] ? -mag : +mag;
//   }
//   if (!frozen) intfilter = sext10(intfilter + sum);
//   next_sample = (intfilter << 6) | (((intfilter & 0x3ff) ^ 0x200) >> 4);
//   agc = !(intfilter >= 0x100 || intfilter <= -0x100);
//
// The `next_sample` expression reduces exactly to the bit concatenation
//   { intfilter[9:0], ~intfilter[9], intfilter[8:4] }
// (a 16-bit signed value): `^0x200 >> 4` is just "flip bit 9, take bits 9:4".
//
// RESET (hc55516_device::device_reset): sylfilter = 0x3f, intfilter = 0,
// agc = 1, /FZ buffered inactive -- "simulate /FZ having been held for a
// while".
//
// CLOCKING ON THIS BOARD
// -----------------------------------------------------------------------------
// The S11 background board drives the CVSD clock and data pin ENTIRELY IN
// SOFTWARE from the 6809 (s11c_bg.cpp:520-533):
//     write 0x6000 (mirror 0x07ff) -> clock_w(1)
//     write 0x6800 (mirror 0x07ff) -> clock_w(0); digit_w(data & 1)
// and `clock_w` only calls `process_bit` when the level actually CHANGES
// (`is_clock_changed`). Both facts are modelled literally below: `clk_set` /
// `clk_clr` are single-`clk` strobes decoded by williams_bg.sv, and the
// level-change guard is the `clk_state` register.
//
// The MAME order inside the 0x6800 handler is clock_w(0) FIRST, then digit_w --
// i.e. the falling edge is processed against the PREVIOUS bit and the new bit
// only takes effect at the next rising edge. Non-blocking assignment gives that
// ordering for free here (the `process` block reads the old `buf_bit` while the
// same clocked block schedules `buf_bit <= digit`).
//
// This module has NO clock of its own and NO gated clock: everything is on
// `clk`, qualified by the two strobes.
// =============================================================================

`default_nettype none

module hc55516 (
    input  logic        clk,
    input  logic        rst,        // synchronous, active high

    // Software-driven clock pin. Single-`clk` strobes; a strobe whose level
    // matches the current state is ignored, exactly as MAME's
    // `is_clock_changed` guard does.
    input  logic        clk_set,    // write to 0x6000 -> clock_w(1)
    input  logic        clk_clr,    // write to 0x6800 -> clock_w(0)
    input  logic        digit,      // digit_w value, latched WITH clk_clr

    // /FZ ("force zero"). The S11 board leaves this pin inactive -- s11c_bg.cpp
    // registers no fzq callback, so MAME's `m_buffered_fzq` stays at its
    // power-on `true`. Exposed for completeness and tied 1 by williams_bg.sv.
    input  logic        fzq_n,      // 1 = inactive (normal decode)

    output logic signed [15:0] sample,
    output logic        agc
);

    // ---- state ---------------------------------------------------------------
    logic               clk_state;      // m_last_clock_state
    logic               buf_bit;        // m_buffered_bit
    // m_shiftreg. MAME keeps 8 bits but reads only (shiftreg & 0x7) for the
    // coincidence test and (shiftreg & 1) for the inactive-edge sign, so only the
    // two bits that survive one shift into the mask need storing.
    logic [1:0]         shiftreg;
    logic [11:0]        sylfilter;      // m_sylfilter (always masked to 0xfff)
    logic signed [9:0]  intfilter;      // m_intfilter (always sext to 10 bits)

    // ---- per-transition combinational datapath --------------------------------
    // Two independent "would-be" results are computed every cycle; the clocked
    // block below commits at most one of them. Keeping them combinational costs
    // nothing (they are 12-bit adds) and keeps the sequential block readable.

    logic               rising;         // this transition is the active edge
    logic               falling;
    assign rising  = clk_set & ~clk_state;
    assign falling = clk_clr &  clk_state;

    // frozen: computed from the CURRENT intfilter and the RAW buffered bit.
    logic frozen;
    assign frozen = ((intfilter >=  10'sd384) & ~buf_bit) |   // >=  0x180
                    ((intfilter <= -10'sd384) &  buf_bit);    // <= -0x180

    // -- rising-edge path ------------------------------------------------------
    logic       eff_bit;                // bit after the /FZ substitution
    logic [2:0] shift_nx;
    logic       coincidence;
    logic [5:0] syl_step;
    logic [11:0] syl_nx;

    assign eff_bit     = fzq_n ? buf_bit : ~shiftreg[0];
    assign shift_nx    = {shiftreg, eff_bit};
    assign coincidence = (shift_nx == 3'b000) | (shift_nx == 3'b111);
    // ((~sylfilter) & 0xfc0) >> 6  -- a 6-bit quantity
    assign syl_step    = ~sylfilter[11:6];
    assign syl_nx      = sylfilter + {6'b0, syl_step}
                                   + (coincidence ? 12'h000 : 12'hfc1);

    // sum on the active edge: sext10( ((~intfilter) >> 4) + 1 ).
    // 16 bits is ample: ~intfilter is in [-512, 511] like intfilter itself.
    logic signed [15:0] inv_int;
    // Only bits 9:0 of the two sums are consumed -- util::sext(..., 10) discards
    // the rest by construction, so the upper bits are deliberately dead.
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [15:0] sum_rise16;
    assign inv_int    = ~{{6{intfilter[9]}}, intfilter};
    assign sum_rise16 = (inv_int >>> 4) + 16'sd1;

    // sum on the inactive edge: +/- max(2, sylfilter >> 6)
    logic [5:0]         syl_mag6;
    logic signed [15:0] sum_fall16;
    /* verilator lint_on UNUSEDSIGNAL */
    assign syl_mag6   = (sylfilter[11:6] < 6'd2) ? 6'd2 : sylfilter[11:6];
    assign sum_fall16 = shiftreg[0] ? -$signed({10'b0, syl_mag6})
                                    :  $signed({10'b0, syl_mag6});

    // sext10 of either sum, then intfilter + sum, then sext10 again.
    logic signed [9:0] sum10;
    logic signed [9:0] int_nx;
    assign sum10  = rising ? sum_rise16[9:0] : sum_fall16[9:0];
    assign int_nx = intfilter + sum10;      // 10-bit wrap == util::sext(...,10)

    // ---- sequential ----------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            clk_state <= 1'b0;
            buf_bit   <= 1'b0;
            shiftreg  <= 2'b00;
            sylfilter <= 12'h03f;           // device_reset(): 0x3f
            intfilter <= 10'sd0;
            sample    <= 16'sd0;
            agc       <= 1'b1;
        end else begin
            // digit_w -- always applied when the 0x6800 handler runs, AFTER the
            // falling edge has been processed against the previous bit.
            if (clk_clr) buf_bit <= digit;

            // clock_w level tracking (only the two decoded strobes move it)
            if (clk_set) clk_state <= 1'b1;
            if (clk_clr) clk_state <= 1'b0;

            if (rising | falling) begin
                if (rising) begin
                    shiftreg <= shift_nx[1:0];
                    if (!frozen) sylfilter <= syl_nx;   // (the &0xfff is the width)
                end

                if (!frozen) begin
                    intfilter <= int_nx;
                    sample    <= {int_nx, ~int_nx[9], int_nx[8:4]};
                    agc       <= ~((int_nx >=  10'sd256) | (int_nx <= -10'sd256));
                end else begin
                    // intfilter unchanged, but MAME still recomputes the output
                    // and the AGC flag from it.
                    sample    <= {intfilter, ~intfilter[9], intfilter[8:4]};
                    agc       <= ~((intfilter >=  10'sd256) | (intfilter <= -10'sd256));
                end
            end
        end
    end

endmodule

`default_nettype wire
