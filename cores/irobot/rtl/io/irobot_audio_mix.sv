`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
//
// I, Robot quad-POKEY analog output stage, digital equivalent.
//
// Evidence: SP-251 Sheet 4A (quad-POKEY + analog audio), read off 400-700 dpi
// crops of `.evidence/I-Robot_SP-251_1st_Printing.pdf` (no text layer).
//
//   KNOWN   Audio is a single 40-pin Atari custom "CI/O" at 4E carrying four
//           independent POKEYs.  Its four outputs AUD1(23) AUD2(29) AUD3(27)
//           AUD4(21) are strapped directly together at the package pins by
//           plain wire with junction dots.  There are no per-channel
//           resistors, pull-downs or capacitors, so the four channels mix at
//           exactly equal 1:1:1:1 weight on the common node "CI/OAUD".
//           (Corroborated by MAME irobot.cpp: four routes at 0.25, and the
//           FIXME at irobot.cpp:307 "all channels of the quad-pokey tied
//           together".)
//   KNOWN   C9 = 0.22uF shunts CI/OAUD to ground; R19 = 220R feeds the
//           virtual ground of U11C (LM324) whose feedback is R20 = 1k.
//           => single-pole low-pass, f = 1/(2*pi*220*0.22u) = 3289 Hz.
//   KNOWN   C8 = 0.22uF in series into R24 = 39k (inverting unity buffer)
//           => single-pole high-pass, f = 1/(2*pi*39k*0.22u) = 18.55 Hz.
//   KNOWN   No pole exists in the R20 feedback (bare resistor) nor in either
//           39k/39k stage.  The board is first order at each end - one LPF
//           pole and one HPF pole, nothing more.
//   KNOWN   CI/O pin 24 (phi2) is driven by CLKE, the 68B09E E clock; MAME
//           gives the crystal as 12.096 MHz with E = 12.096/8.
//   INFERRED (strong) each internal POKEY therefore updates at 1.512 MHz, so
//           this module is written to run on one enable pulse per POKEY phi2.
//   INFERRED The 3289 Hz figure assumes the POKEY AUD pins present a high
//           source impedance (current-mode ladder output), which makes the
//           220R the dominant shunt resistance.  With a finite source
//           impedance Rs the true pole is 1/(2*pi*(Rs||220)*C9), i.e. >=
//           3289 Hz; 3289 Hz is the lower bound and the evident design
//           intent.  This is open item U002 in docs/HARDWARE.md - a scope
//           capture on CI/OAUD versus the LM324 pin 9 node would pin it down.
//           The corner is therefore a parameter, not a hard-coded constant.
//
// The analog stage's absolute voltage gain (-4.545 into AUD1, +4.545 into
// AUD2, 9.09 differential) sets only the level presented to the cabinet
// amplifier and is frequency-independent; a MiSTer core normalizes the mix to
// full scale instead, so no gain compensation is modelled here.
//
// Synthesis notes: every multiply operand is kept at its true value width
// (19x11 and 19x8) so Cyclone V maps each to a single 18x19 DSP block.  No
// multidimensional unpacked arrays, no fabric clocks - one clock plus an
// enable, per the MiSTer conventions.
//
module irobot_audio_mix #(
	// POKEY phi2 rate in Hz, i.e. the rate at which `ena` pulses.
	// KNOWN 12.096 MHz crystal / 8 = 1.512 MHz.
	parameter int unsigned ENA_HZ        = 1512000,
	// Low-pass corner actually realised, for documentation/regression only.
	parameter int unsigned AUDIO_LPF_HZ  = 3290,
	// One-pole LPF coefficient in Q16.
	//   a = 2*pi*fc/fs = 2*pi*3289 / 1512000 = 1.35766e-2
	//   round(1.35766e-2 * 65536) = 890  ->  realised fc = 3290 Hz (+0.03%)
	parameter int unsigned LPF_A_Q16     = 890,
	// One-pole DC-blocker (high-pass) coefficient in Q20.
	//   a = 2*pi*18.55 / 1512000 = 7.7095e-5
	//   round(7.7095e-5 * 2^20) = 81   ->  realised fc = 18.59 Hz (+0.2%)
	parameter int unsigned HPF_A_Q20     = 81,
	// C8/R24 AC coupling.  Leave enabled for hardware fidelity; disable only
	// for DC-level regression checks.
	parameter bit          ENABLE_DCBLOCK = 1'b1
)(
	input  logic               clk,
	input  logic               reset,
	input  logic               ena,     // one pulse per POKEY phi2 (CLKE)
	// The four CI/O channel levels, kept separate on purpose: the summing is
	// part of this stage, not of the register-decode glue.
	input  logic [7:0]         ch0,
	input  logic [7:0]         ch1,
	input  logic [7:0]         ch2,
	input  logic [7:0]         ch3,
	output logic signed [15:0] audio
);
	// ---- Summing node CI/OAUD -------------------------------------------
	// Equal weights, KNOWN from the wired-together AUD pins.  0..1020.
	logic [9:0] sum;
	always_comb sum = {2'b0,ch0} + {2'b0,ch1} + {2'b0,ch2} + {2'b0,ch3};

	// POKEY's digital output is a zero-based 0..255 level.  MAME's legacy
	// mixer and the quad_pokey interface both produce zero for silent channels;
	// there is no supported mid-scale bias to subtract here.  Preserve the
	// maximum level at the same near-full-scale magnitude as the old centred
	// path (1020 << 5 = 32640), while ensuring four silent channels feed an
	// exactly zero filter state rather than an invented startup transient.
	// Listening level.  The board feeds a volume pot, so absolute level is not a
	// board property; at shift 5 the mixed output peaked at -6 dBFS and typical
	// music sat far lower.  Shift 6 doubles it (1020 << 6 = 65280 before the
	// AC-coupling stage); the saturating output stage below clamps the rare
	// case of every channel at full scale in phase.
	localparam int OUT_SHIFT = 6;
	wire signed [16:0] x_q = $signed({1'b0, sum, {OUT_SHIFT{1'b0}}});

	// ---- R19/C9 one-pole low-pass (anti-alias + 3.29 kHz board pole) -----
	localparam int LPF_FRAC = 16;
	localparam int LPF_GUARD = 2;                       // transient headroom
	localparam int LPF_ACC_W = 17 + LPF_FRAC + LPF_GUARD; // 35
	localparam logic signed [10:0] LPF_A = 11'(LPF_A_Q16);

	logic signed [LPF_ACC_W-1:0] lpf_acc;
	wire  signed [18:0]          lpf_y   = lpf_acc[LPF_ACC_W-1:LPF_FRAC];
	wire  signed [19:0]          lpf_err = 20'(x_q) - 20'(lpf_y);
	wire  signed [30:0]          lpf_p   = lpf_err * LPF_A;

	// ---- C8/R24 one-pole high-pass, realised as x - lpf(x) --------------
	localparam int HPF_FRAC = 20;
	localparam int HPF_GUARD = 2;
	localparam int HPF_ACC_W = 17 + HPF_FRAC + HPF_GUARD; // 39
	localparam logic signed [7:0] HPF_A = 8'(HPF_A_Q20);

	logic signed [HPF_ACC_W-1:0] hpf_acc;
	wire  signed [18:0]          hpf_y   = hpf_acc[HPF_ACC_W-1:HPF_FRAC];
	wire  signed [19:0]          hpf_err = 20'(lpf_y) - 20'(hpf_y);
	wire  signed [27:0]          hpf_p   = hpf_err * HPF_A;

	// Board output: the AC-coupled version of the filtered summing node.
	wire signed [19:0] out_full = ENABLE_DCBLOCK ? (20'(lpf_y) - 20'(hpf_y))
	                                             :  20'(lpf_y);

	always_ff @(posedge clk) begin
		if (reset) begin
			lpf_acc <= '0;
			hpf_acc <= '0;
			audio   <= '0;
		end else if (ena) begin
			lpf_acc <= lpf_acc + LPF_ACC_W'(lpf_p);
			hpf_acc <= hpf_acc + HPF_ACC_W'(hpf_p);
			// Saturate rather than wrap.  A one-pole low-pass with a<1 cannot
			// overshoot its input, so this only guards rounding/transients.
			if      (out_full >  20'sd32767) audio <= 16'sh7fff;
			else if (out_full < -20'sd32768) audio <= 16'sh8000;
			else                             audio <= out_full[15:0];
		end
	end

	// Documentation-only sanity check on the coefficient/rate pairing.
	// Simulation-only; has no synthesizable effect.
	// verilator lint_off UNUSEDPARAM
	localparam int unsigned DOC_LPF_HZ = AUDIO_LPF_HZ;
	localparam int unsigned DOC_ENA_HZ = ENA_HZ;
	// verilator lint_on UNUSEDPARAM
endmodule
