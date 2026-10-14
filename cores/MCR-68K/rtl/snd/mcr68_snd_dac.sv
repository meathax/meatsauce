// mcr68_snd_dac.sv -- Sounds Good board AD7533 DAC output filter model
// ---------------------------------------------------------------------------
// Bally/Midway MCR-68k "Sounds Good" board (A080-91863-B000) DAC/audio-output
// chain per C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md,
// "Sound" section:
//
//   AD7533 10-bit multiplying DAC, code formed by the PIA as
//     dac10[9:2] = PA[7:0]
//     dac10[1:0] = PB[7:6]
//   (concatenation only -- not modelled as a separate chip, exactly as the
//   donor sounds_good.vhd does it), followed by three cascaded LM359 MFB
//   (multiple-feedback) low-pass filter stages, fc (combined -3dB corner)
//   documented as approximately 4.9-5.4 kHz.
//
// The plan explicitly directs: "reuse jtframe_pole/jtframe_dcrm rather than
// modelling each biquad exactly." This module is that reuse: it does NOT
// attempt to replicate the three individual MFB stage transfer functions.
// It approximates their combined effect as a single dominant real pole at a
// corner frequency inside the documented 4.9-5.4 kHz band, using jtframe's
// generic single-pole IIR (jtframe_pole). DC removal is a separate, distinct
// step handled by jtframe_dcrm -- see rationale below.
//
// Both jtframe_pole and jtframe_dcrm are read-only vendored third-party
// files (D:\Arcade\AI\aCORES\midway68\third_party\jtframe\sound\) and are
// NOT modified by this module.
//
// Scope note: this file, and everything under rtl/snd, sim, and tools that
// this task touches, is new and self-contained. It does not instantiate or
// modify rtl/mcr68_main_board.sv, rtl/cpu/fx68k.sv, rtl/cpu/mcr68_m68k.sv or
// sim/sim_mcr68_headless.cpp (another investigation is mid-edit on those).
// Wiring mcr68_snd_dac into the main board's sound section (i.e. connecting
// dac10 from a future rtl/snd/sounds_good.sv instance and routing audio_o to
// the top level) is explicitly out of scope here and lands separately.
// ---------------------------------------------------------------------------
//
// DC-removal-then-filter chain rationale
// ---------------------------------------------------------------------------
// dac10 is an UNSIGNED 10-bit code (0..1023) with its "silence" level sitting
// wherever the Sounds Good firmware centres it -- typically near mid-scale,
// i.e. a large, content-dependent DC bias relative to true zero. Treating
// dac10 as a signed sample directly (e.g. by simple sign-extension after
// subtracting a fixed constant 512) would leave any drift between the
// firmware's actual DC operating point and an assumed constant as an
// uncorrected offset, and would inject that offset as a jarring low-frequency
// step/thump on every reset or level change, plus it would eat into the
// -3dB corner of a downstream low-pass filter given no HPF stage exists to
// null it first.
//
// On real hardware the three LM359 MFB stages are individually AC-coupled
// (their op-amp bias networks and coupling caps null exactly this kind of
// slowly-varying/DC bias), so a discrete DC-removal step upstream of the
// low-pass modelling is the correct order of operations, not an approximation
// shortcut: it plays the same role the analog bias/coupling network plays,
// before the single dominant pole approximates the three stages' combined
// roll-off.
//
// jtframe_dcrm implements exactly that: a leaky-integrator DC blocker (the
// same structure used elsewhere in jtframe as jt49_dcrm2) that continuously
// tracks the running average of an UNSIGNED input and subtracts it, producing
// a zero-centred SIGNED output of the same width. Feeding it dac10 directly
// (SIGNED_INPUT=0) is therefore the first stage.
//
// The DC-removed value is still only 10 bits wide (range roughly -512..+511).
// It is then left-justified into the 16-bit signed field this project's
// audio path expects (see "Output width" below) by an arithmetic left shift
// of 6 bits (x64), before entering the low-pass stage. Filtering after
// widening (rather than before) avoids any extra rounding step: jtframe_pole
// already carries WS+WA extra internal bits of precision internally, so it
// loses nothing operating on the widened value, and the widening itself is
// exact (a pure left shift, no bits are dropped).
//
// Chain: dac10 (10b unsigned) -> jtframe_dcrm (DC removal, 10b unsigned in,
// 10b signed out) -> left-shift x64 (10b signed -> 16b signed, MSB-aligned)
// -> jtframe_pole (single-pole low-pass, 16b signed) -> audio_o.
//
// Output width
// ---------------------------------------------------------------------------
// sys/audio_out.sv (read-only, vendored MiSTer framework) takes its
// `core_l`/`core_r` core-audio inputs as `input [15:0]`, gated by an
// `is_signed` select, and its sibling sys/sigma_delta_dac.v is likewise
// driven from a signed 16-bit-derived field further down that same chain
// (`{~al[15], al[14:0]}`) -- both confirm this project's audio path is
// 16-bit signed PCM. audio_o is declared `signed [15:0]` to match that
// convention directly; a future integration step drives sys/audio_out.sv's
// core_l/core_r from this module's audio_o with is_signed=1.
//
// jtframe_pole coefficient derivation for the target cutoff
// ---------------------------------------------------------------------------
// jtframe_pole computes, once per `sample` pulse:
//     y[k] = a*y[k-1] + (1-a)*(x[k]+x[k-1])/1   (see jtframe_pole.v header;
//                                                 implemented via its own
//                                                 fixed-point pipeline)
// with the standard single-pole design relation given in that file's header:
//     a = 1 / (1 + wc),  wc = 2*pi*fc / fs
// where fc is the desired -3dB corner and fs is the rate at which `sample`
// pulses (i.e. the filter's own internal decimation/update rate, NOT the
// `clk` frequency -- `clk` just has to be fast enough to run the pipeline
// between `sample` pulses, which it is by construction here: see "Internal
// sample-rate generation" below).
//
// Parameters chosen:
//   FC_HZ     = 5150      -- arithmetic midpoint of the plan's documented
//                            4.9-5.4 kHz combined LM359 MFB corner range.
//   SAMPLE_HZ = 48000      -- matches sys/audio_out.sv's fixed AUDIO_RATE
//                            (localparam AUDIO_RATE = 48000), so no further
//                            resampling stage is implied when this module's
//                            output eventually feeds that path.
//   WS = 16, WA = 8        -- jtframe_pole's own default (WA=WS/2) applied
//                            explicitly; a is therefore an unsigned Q0.8
//                            fraction (8 bits, range 0 .. 255/256).
//
// Math:
//   wc = 2*pi * 5150 / 48000
//      = 6.283185307 * 5150 / 48000
//      = 32358.404 / 48000
//      = 0.674133 rad
//   a  = 1 / (1 + 0.674133) = 1 / 1.674133 = 0.597324
//   a in Q0.8 = round(0.597324 * 256) = round(152.915) = 153
//
// POLE_A_Q8 = 8'd153 is therefore the coefficient passed to jtframe_pole's
// `a` port. Back-substituting the *quantised* coefficient to see the actual
// realised corner (since 153/256 != 0.597324 exactly):
//   a_actual  = 153/256 = 0.597656
//   wc_actual = 1/a_actual - 1 = 256/153 - 1 = 1.673203 - 1 = 0.673203 rad
//   fc_actual = wc_actual * fs / (2*pi) = 0.673203 * 48000 / 6.283185
//             = 32313.73 / 6.283185
//             = 5143.96 Hz  ~= 5144 Hz
//
// 5144 Hz falls inside the plan's documented 4.9-5.4 kHz band with margin on
// both sides, so no further coefficient search was needed. If SAMPLE_HZ or
// FC_HZ are overridden, POLE_A_Q8 must be recomputed by hand with the same
// formula and passed in explicitly -- it is a plain constant, not derived
// from real-valued elaboration-time arithmetic, so that this module's
// synthesizability does not depend on a Quartus-17-era `real`/$rtoi
// parameter-folding path.
//
// Internal sample-rate generation
// ---------------------------------------------------------------------------
// The AD7533 code has no inherent periodic "sample" strobe of its own -- it
// simply changes whenever the sound 68000 writes a new value to the PIA.
// Both jtframe_dcrm and jtframe_pole are however built around a periodic
// `sample` pulse (single `clk`-wide) that is expected to be slow relative to
// `clk`, so that at least one `sample=0` cycle separates consecutive
// `sample=1` pulses (jtframe_pole's 2-stage multiply-accumulate pipeline
// needs that gap; see the file's internals). This module therefore
// generates its own SAMPLE_HZ-rate `sample` pulse train from `clk` using the
// same fixed-point phase-accumulator idiom already used in this project's
// vendored sys/audio_out.sv (`mclk_ce`): accumulate SAMPLE_HZ every `clk`
// cycle modulo CLK_HZ, pulse `sample_tick` on wraparound. This is exact
// on average and jitters by at most one `clk` period, which is immaterial
// at audio rates.
//
// CLK_HZ defaults to 8_000_000 Hz -- the Sounds Good board's sound 68000
// clock (40 MHz / 5, per midway_sound.cpp:607 and the donor sounds_good.vhd)
// -- because dac10 is expected to be produced by rtl/snd/sounds_good.sv in
// that same clock domain (a PIA output register clocked by the sound CPU
// clock), so driving this module's `clk` from that same domain avoids any
// clock-domain-crossing on dac10 at this module's input boundary. Override
// CLK_HZ if a future integration instantiates this module on a different
// clock.
// ---------------------------------------------------------------------------

module mcr68_snd_dac #(
    parameter int CLK_HZ    = 8_000_000,  // frequency of `clk`, Hz (see header)
    parameter int SAMPLE_HZ = 48_000,     // internal filter update rate, Hz
    /* verilator lint_off UNUSEDPARAM */
    parameter int FC_HZ     = 5_150,      // target -3dB corner, Hz -- documentation only: POLE_A_Q8
                                           // below is the hand-derived constant actually consumed by
                                           // the RTL (see header "jtframe_pole coefficient derivation"),
                                           // so this parameter is intentionally not read anywhere.
    /* verilator lint_on UNUSEDPARAM */

    // Q0.8 unsigned single-pole coefficient for jtframe_pole, derived by hand
    // from FC_HZ/SAMPLE_HZ above -- see "jtframe_pole coefficient derivation"
    // in the header comment. Recompute and override if FC_HZ/SAMPLE_HZ change.
    parameter logic [7:0] POLE_A_Q8 = 8'd153
) (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high (matches jtframe_pole/jtframe_dcrm convention)

    input  logic [9:0]  dac10,      // unsigned AD7533 code from sounds_good.sv: {PA[7:0], PB[7:6]}

    output logic signed [15:0] audio_o,   // filtered, DC-free, 16-bit signed audio sample
                                            // (sys/audio_out.sv core_l/core_r convention, is_signed=1)
    output logic        sample_o    // internal SAMPLE_HZ decimation tick, exported for
                                     // testbench/verification use only (audio_o is valid
                                     // continuously; this just marks when it last updated)
);

    // -------------------------------------------------------------------
    // Input boundary register: one clk of synchronization so this module's
    // internal combinational fan-in (jtframe_dcrm's `din` use) does not
    // depend on whatever produces dac10 being itself glitch-free.
    // -------------------------------------------------------------------
    logic [9:0] dac10_r;
    always_ff @(posedge clk) begin
        dac10_r <= dac10;
    end

    // -------------------------------------------------------------------
    // SAMPLE_HZ-rate `sample` pulse generator (phase accumulator), same
    // idiom as sys/audio_out.sv's mclk_ce.
    // -------------------------------------------------------------------
    logic [31:0] sample_acc;
    logic        sample_tick;

    assign sample_tick = (sample_acc + SAMPLE_HZ) >= CLK_HZ;

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_acc <= '0;
        end else if (sample_tick) begin
            sample_acc <= sample_acc + SAMPLE_HZ - CLK_HZ;
        end else begin
            sample_acc <= sample_acc + SAMPLE_HZ;
        end
    end

    assign sample_o = sample_tick;

    // -------------------------------------------------------------------
    // Stage 1: DC removal (unsigned -> signed, same width)
    // -------------------------------------------------------------------
    logic signed [9:0] dcrm_out;

    jtframe_dcrm #(
        .SW          (10),
        .SIGNED_INPUT(0)
    ) u_dcrm (
        .rst   (rst),
        .clk   (clk),
        .sample(sample_tick),
        .din   (dac10_r),
        .dout  (dcrm_out)
    );

    // -------------------------------------------------------------------
    // Widen: 10-bit signed -> 16-bit signed, MSB-aligned (x64, exact left
    // shift -- no bits of dcrm_out are dropped, see header).
    // -------------------------------------------------------------------
    logic signed [15:0] dcrm_out16;
    assign dcrm_out16 = $signed({dcrm_out, 6'b0});

    // -------------------------------------------------------------------
    // Stage 2: single-pole low-pass approximating the 3 cascaded LM359 MFB
    // stages' combined ~4.9-5.4 kHz corner (see coefficient derivation above).
    // -------------------------------------------------------------------
    jtframe_pole #(
        .WS(16),
        .WA(8)
    ) u_pole (
        .rst   (rst),
        .clk   (clk),
        .sample(sample_tick),
        .sin   (dcrm_out16),
        .a     (POLE_A_Q8),
        .sout  (audio_o)
    );

endmodule
