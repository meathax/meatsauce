// SPDX-License-Identifier: GPL-3.0-or-later
// Exact-rational mixer for the four AD7524 routes, AD7533, and mono-folded
// YM2151 route used by the pinned Asylum WSF configuration. The two unused
// generic Leland DAC lanes are present in the interface and ignored here.
// All route terms share a denominator of five and are summed before one
// truncation toward zero and signed-16 clipping.
module leland_dac_mixer_wsf_candidate (
	input  logic clk,
	input  logic reset,
	input  logic [7:0] dac_sample [0:5],
	input  logic [7:0] dac_vol    [0:5],
	input  logic [9:0] dac9_sample,
	input  logic signed [15:0] ym_left,
	input  logic signed [15:0] ym_right,
	output logic signed [15:0] audio_out
);

function automatic logic signed [20:0] dac8_numerator(
	input logic [7:0] sample_code,
	input logic [7:0] volume_code
);
	logic signed [8:0] delta;
	logic signed [17:0] product;
	begin
		delta = $signed({1'b0, sample_code}) - 9'sd128;
		product = delta * $signed({1'b0, volume_code});
		dac8_numerator = $signed({{3{product[17]}}, product}) <<< 1;
	end
endfunction

function automatic logic signed [20:0] dac9_numerator(
	input logic [9:0] sample_code
);
	logic signed [10:0] delta;
	logic signed [20:0] product;
	begin
		delta = $signed({1'b0, sample_code}) - 11'sd512;
		product = delta * 21'sd320;
		dac9_numerator = product;
	end
endfunction

logic signed [16:0] ym_sum;
logic signed [20:0] ym_numerator;
logic signed [20:0] mix_numerator;
logic signed [20:0] mix_numerator_r;
logic signed [21:0] numerator_ext;
logic [21:0] numerator_magnitude;
logic [21:0] quotient_magnitude;
logic signed [21:0] truncated_value;

always_comb begin
	ym_sum = $signed({ym_left[15], ym_left}) + $signed({ym_right[15], ym_right});
	ym_numerator = $signed({{4{ym_sum[16]}}, ym_sum}) <<< 1;
	mix_numerator = dac8_numerator(dac_sample[0], dac_vol[0]) +
	                dac8_numerator(dac_sample[1], dac_vol[1]) +
	                dac8_numerator(dac_sample[2], dac_vol[2]) +
	                dac8_numerator(dac_sample[3], dac_vol[3]) +
	                dac9_numerator(dac9_sample) + ym_numerator;

	numerator_ext = $signed({mix_numerator_r[20], mix_numerator_r});
	if (numerator_ext < 0)
		numerator_magnitude = $unsigned(-numerator_ext);
	else
		numerator_magnitude = $unsigned(numerator_ext);
	quotient_magnitude = numerator_magnitude / 22'd5;
	if (numerator_ext < 0)
		truncated_value = -$signed(quotient_magnitude);
	else
		truncated_value = $signed(quotient_magnitude);
end

// Keep the same two rising-edge pipeline depth as the existing mixer: the
// common-denominator route sum is registered first, then converted/clipped.
always_ff @(posedge clk or posedge reset) begin
	if (reset) begin
		mix_numerator_r <= 21'sd0;
		audio_out <= 16'sd0;
	end else begin
		mix_numerator_r <= mix_numerator;
		if (truncated_value > 22'sd32767)
			audio_out <= 16'sd32767;
		else if (truncated_value < -22'sd32768)
			audio_out <= -16'sd32768;
		else
			audio_out <= truncated_value[15:0];
	end
end

endmodule

// Profile zero is the exact legacy path. Profile one selects the rational
// mixer only for WSF; all other board variants retain the legacy mixer.
module leland_dac_mixer_profile #(
	parameter integer WSF_MIXER_PROFILE = 0
)(
	input  logic clk,
	input  logic reset,
	input  logic wsf_mode,
	input  logic [7:0] dac_sample [0:5],
	input  logic [7:0] dac_vol    [0:5],
	input  logic [9:0] dac9_sample,
	input  logic signed [15:0] ym_left,
	input  logic signed [15:0] ym_right,
	output logic signed [15:0] audio_out
);

generate
	if (WSF_MIXER_PROFILE == 0) begin : g_legacy_default
		leland_dac_mixer legacy_mixer(
			.clk(clk), .reset(reset),
			.dac_sample(dac_sample), .dac_vol(dac_vol), .dac9_sample(dac9_sample),
			.ym_left(ym_left), .ym_right(ym_right), .audio_out(audio_out));
	end else if (WSF_MIXER_PROFILE == 1) begin : g_wsf_selectable
		logic signed [15:0] legacy_audio;
		logic signed [15:0] wsf_audio;

		leland_dac_mixer legacy_mixer(
			.clk(clk), .reset(reset),
			.dac_sample(dac_sample), .dac_vol(dac_vol), .dac9_sample(dac9_sample),
			.ym_left(ym_left), .ym_right(ym_right), .audio_out(legacy_audio));
		leland_dac_mixer_wsf_candidate wsf_mixer(
			.clk(clk), .reset(reset),
			.dac_sample(dac_sample), .dac_vol(dac_vol), .dac9_sample(dac9_sample),
			.ym_left(ym_left), .ym_right(ym_right), .audio_out(wsf_audio));

		always_comb audio_out = wsf_mode ? wsf_audio : legacy_audio;
	end else begin : g_invalid_profile
		assign audio_out = 16'sd0;
		initial $fatal(1, "Unsupported WSF_MIXER_PROFILE=%0d", WSF_MIXER_PROFILE);
	end
endgenerate

endmodule
