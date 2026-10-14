`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Cabinet-calibrated Hall-stick conversion. MAME's measured service ranges are
// Y=96..163 and X=96..159 with X reversed. Digital input follows the same
// endpoints and optionally slews one ADC count per update.
module irobot_controls (
	input  logic              clk,
	input  logic              reset,
	input  logic              ce_update,
	input  logic signed [7:0] analog_x,
	input  logic signed [7:0] analog_y,
	input  logic              analog_valid,
	input  logic              left,
	input  logic              right,
	input  logic              up,
	input  logic              down,
	input  logic              instant_digital,
	output logic [7:0]        adc_x,
	output logic [7:0]        adc_y
);
	logic [7:0] target_x,target_y;
	logic signed [15:0] scaled_x,scaled_y,value_x,value_y;
	always_comb begin
		if (analog_valid) begin
			// The measured cabinet ranges are asymmetric about center.
			scaled_x = analog_x >= 0 ? (analog_x * -16'sd32) / 16'sd127
			                           : (analog_x * -16'sd31) / 16'sd128;
			scaled_y = analog_y >= 0 ? (analog_y *  16'sd35) / 16'sd127
			                           : (analog_y *  16'sd32) / 16'sd128;
			value_x = 16'sd128 + scaled_x;
			value_y = 16'sd128 + scaled_y;
			target_x = value_x < 96 ? 8'd96 : value_x > 159 ? 8'd159 : value_x[7:0];
			target_y = value_y < 96 ? 8'd96 : value_y > 163 ? 8'd163 : value_y[7:0];
		end else begin
			scaled_x = 0; scaled_y = 0; value_x = 0; value_y = 0;
			target_x = left && !right ? 8'd159 : right && !left ? 8'd96 : 8'd128;
			target_y = up && !down ? 8'd96 : down && !up ? 8'd163 : 8'd128;
		end
	end
	always_ff @(posedge clk) begin
		if (reset) begin adc_x<=8'd128; adc_y<=8'd128; end
		else if (ce_update) begin
			if (analog_valid || instant_digital) begin adc_x<=target_x; adc_y<=target_y; end
			else begin
				if(adc_x<target_x) adc_x<=adc_x+1'd1; else if(adc_x>target_x) adc_x<=adc_x-1'd1;
				if(adc_y<target_y) adc_y<=adc_y+1'd1; else if(adc_y>target_y) adc_y<=adc_y-1'd1;
			end
		end
	end
endmodule
