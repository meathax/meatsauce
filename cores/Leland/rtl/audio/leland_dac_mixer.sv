// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// leland_dac_mixer -- DAC/mixer datapath.
//
// Takes the sound board's digital DAC register outputs (six 8-bit sample+volume pairs
// and one 10-bit sample) and produces one mono signed 16-bit PCM stream; the top level
// duplicates it to both channels (leland_a.cpp has a single front_center speaker).
//
// Each 8-bit channel is an AD7524 multiplying DAC whose reference is driven by a second
// DAC (the volume register), so the output is proportional to sample * volume. `sample`
// is offset-binary (128 is zero) and `volume` is a plain 0-255 gain. dac9 (AD7533) has
// no volume register, is offset-binary centred at 512, and has gain 1.0.
//
// Gains: leland_a.cpp routes each 8-bit channel at 0.2 and dac9 at 1.0. MAME's volume DAC
// (DAC_8BIT_BINARY_WEIGHTED) has a gain of 2.0, which doubles every 8-bit channel (measured
// against a MAME capture of Indy Heat). Implemented as Q8 multipliers (GAIN_8BIT=102/256,
// GAIN_10BIT=255/256). dac9's signed range (-512..511)
// is first scaled by DAC9_SCALE to match one 8-bit channel's full-scale product
// (~32640), so both channel types land in a comparable range before summing.
module leland_dac_mixer(
	input  logic        clk,
	input  logic        reset,

	input  logic [7:0]  dac_sample [0:5],
	input  logic [7:0]  dac_vol    [0:5],
	input  logic [9:0]  dac9_sample,
	input  logic signed [15:0] ym_left,  // YM2151 (WSF), routed at 0.40 per channel
	input  logic signed [15:0] ym_right,

	output logic signed [15:0] audio_out
);

localparam signed [9:0] GAIN_8BIT_Q8  = 10'sd102; // 0.4 (0.2 x the volume DAC's 2.0) * 256, ~0.398
localparam signed [8:0] GAIN_10BIT_Q8 = 9'sd255; // 1.0  * 256, ~0.996
localparam signed [8:0] GAIN_YM_Q8    = 9'sd102; // 0.4  * 256
localparam signed [10:0] DAC9_SCALE   = 11'sd64; // 511*64=32704, comparable to an 8-bit channel's max product (127*255=32385)

logic signed [8:0]  sdiff  [0:5]; // sample - 128
logic signed [16:0] prod   [0:5]; // sdiff * volume
logic signed [24:0] gprod  [0:5]; // prod * GAIN_8BIT_Q8 (pre-shift)
logic signed [16:0] gained [0:5]; // gprod >>> 8

logic signed [10:0] sdiff9;       // dac9_sample - 512
logic signed [17:0] dac9_full;    // sdiff9 * DAC9_SCALE
logic signed [26:0] gprod9;       // dac9_full * GAIN_10BIT_Q8 (pre-shift)
logic signed [17:0] gained9;      // gprod9 >>> 8

logic signed [20:0] sum_all;
logic signed [15:0] sat;

genvar gi;
generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_ch
		always_comb begin
			sdiff[gi]  = $signed({1'b0, dac_sample[gi]}) - 9'sd128;
			prod[gi]   = sdiff[gi] * $signed({1'b0, dac_vol[gi]});
			gprod[gi]  = prod[gi] * GAIN_8BIT_Q8;
			gained[gi] = gprod[gi] >>> 8;
		end
	end
endgenerate

always_comb begin
	sdiff9    = $signed({1'b0, dac9_sample}) - 11'sd512;
	dac9_full = sdiff9 * DAC9_SCALE;
	gprod9    = dac9_full * GAIN_10BIT_Q8;
	gained9   = gprod9 >>> 8;
end

// Pipeline stage: the whole chain from dac_sample/dac_vol through both multiplies, the
// 7-way sum and the saturation did not fit in one 48 MHz clk_sys cycle. One register
// splits the per-channel gain stage (DSP multiplies) from the summation and saturation,
// adding one clk_sys cycle (~21 ns) of audio latency.
logic signed [16:0] gained_r  [0:5];
logic signed [17:0] gained9_r;
logic signed [24:0] gained_ym_r;

always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		gained_r[0] <= 17'sd0; gained_r[1] <= 17'sd0; gained_r[2] <= 17'sd0;
		gained_r[3] <= 17'sd0; gained_r[4] <= 17'sd0; gained_r[5] <= 17'sd0;
		gained9_r   <= 18'sd0;
		gained_ym_r <= 25'sd0;
	end else begin
		gained_r[0] <= gained[0]; gained_r[1] <= gained[1]; gained_r[2] <= gained[2];
		gained_r[3] <= gained[3]; gained_r[4] <= gained[4]; gained_r[5] <= gained[5];
		gained9_r   <= gained9;
		gained_ym_r <= ((ym_left + ym_right) * GAIN_YM_Q8) >>> 8;
	end
end

always_comb begin
	sum_all = gained_r[0] + gained_r[1] + gained_r[2] + gained_r[3] + gained_r[4] + gained_r[5] + gained9_r + gained_ym_r;

	// Saturate to signed 16-bit (MiSTer's AUDIO_L/AUDIO_R width).
	if (sum_all > 21'sd32767)
		sat = 16'sd32767;
	else if (sum_all < -21'sd32768)
		sat = -16'sd32768;
	else
		sat = sum_all[15:0];
end

always_ff @(posedge clk or posedge reset) begin
	if (reset) audio_out <= 16'sd0;
	else       audio_out <= sat;
end

endmodule
