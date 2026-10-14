`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// ADC0809 board model. Conversion length is expressed in ADC clock enables so
// the corrected board divider can be connected without creating another clock.
//
// CONVERSION_CYCLES = 64.  KNOWN (TI/National ADC0808/0809 datasheet): a
// conversion is 8 successive-approximation bits x 8 clock periods = 64 CLK
// periods, which is exactly the datasheet's own t_C = 100 us at f_CLK =
// 640 kHz.  KNOWN (SP-251 sheet 3B): ADC0809 4C pin 10 (CLK) is the board net
// "750KHZ", which is QD of the LS163A at 7E dividing the crystal oscillator by
// 16.  KNOWN (MAME 0.289 irobot.cpp:283, ADC0809 clocked at 12.096_MHz_XTAL/16,
// XTAL taken from the manual parts listing): the oscillator is 12.096 MHz, so
// the real ADC clock is 756.000 kHz and "750KHZ" is a rounded net name.
// INFERRED (arithmetic): 64 / 756000 = 84.66 us per conversion, plus the
// datasheet's 0..8 CLK asynchronous START->EOC latency (0..10.6 us).  No change
// to the count is warranted; the parameter is in ce_adc enables, so the
// integrator supplies the /16 divider (see irobot_peripherals ce_adc note).
//
// CO-251-02 (sheet 3B FROM/TO pair, .evidence/CO-251-02.pdf p.4) replaces the
// first-printing REF(+)=+5V / REF(-)=GND wiring with a divider.  KNOWN resistor
// values, in series from +5 V to GND: R84 220R, R85 620R, R86 220R, with
// REF(+) at the R84/R85 node and REF(-) at the R85/R86 node.
//
//   Rtot = 220+620+220 = 1060R      I = 5.000/1060 = 4.7170 mA
//   VREF- = 4.7170 mA * 220 = 1.0377 V
//   VREF+ = 5.000 - 1.0377   = 3.9623 V   (span 2.9245 V, midpoint 2.5000 V)
//
// This model's `analog` input is the stick voltage expressed on the board's
// 0..5 V rail as 0..255, so the reference endpoints are expressed on that same
// scale (hence the *_CODE parameter names):
//
//   VREF_LOW_CODE  = round(255 * 1.0377/5) =  53   (was 0,   placeholder)
//   VREF_HIGH_CODE = round(255 * 3.9623/5) = 202   (was 255, placeholder)
//
// (53+202)/2 = 127.5, i.e. a centred 2.500 V stick still reads 0x7F/0x80,
// because R84 = R86 keeps the network symmetric.  A stick that only swings
// 2.5 V +/- 1.46 V now reaches 0x00 and 0xFF instead of ~0x33..0xCC, which is
// the point of the correction.
//
// HYPOTHESIS / open parameter (docs/HARDWARE.md U003): the ADC0809's internal
// resistor ladder (datasheet R_LADDER 1.0k min / 2.5k typ / 5.0k max) parallels
// R85, so volts-per-code is uncertain by roughly +/-6 %.  The endpoint codes and
// the 2.500 V midpoint are unaffected by that loading (the network stays
// symmetric), which is why the defaults below are safe; the exact intermediate
// slope is not authenticated and cannot be without a measurement.  Override the
// parameters rather than editing them if a measurement ever lands.
module adc0809 #(
	parameter integer CONVERSION_CYCLES = 64,
	parameter integer ANALOG_WIDTH = 8,
	parameter integer VREF_LOW_CODE = 53,
	parameter integer VREF_HIGH_CODE = 202
) (
	input  logic       clk,
	input  logic       reset,
	input  logic       ce_adc,
	input  logic       start,
	input  logic [2:0] channel,
	input  logic [ANALOG_WIDTH-1:0] analog [0:7],
	output logic [7:0] data,
	output logic       eoc,
	output logic       busy
);
	logic [2:0] selected;
	logic start_d;
	localparam integer COUNT_W = $clog2(CONVERSION_CYCLES+1);
	logic [COUNT_W-1:0] count;
	// Datasheet transfer function: code = 255 * (Vin - VREF-) / (VREF+ - VREF-),
	// clamped at both ends.  The narrowed reference window therefore EXPANDS the
	// input range onto 0..255; with the placeholder 0/255 endpoints this reduces
	// to the identity map exactly as before.  SPAN is a constant expression, so
	// the divide is a constant-divisor divide and stays Quartus 17.0.2-safe.
	localparam integer VREF_SPAN = (VREF_HIGH_CODE > VREF_LOW_CODE) ? (VREF_HIGH_CODE - VREF_LOW_CODE) : 1;
	function automatic [7:0] apply_reference(input logic [ANALOG_WIDTH-1:0] sample);
		integer level;
		integer scaled;
		begin
			// Widen to a signed integer first: mixing the unsigned 8-bit sample
			// with the signed parameter in one expression would make the whole
			// subtraction unsigned and wrap below VREF_LOW_CODE.
			level = int'(sample);
			scaled = ((level - VREF_LOW_CODE) * 255) / VREF_SPAN;
			if (scaled < 0) apply_reference = 8'd0;
			else if (scaled > 255) apply_reference = 8'd255;
			else apply_reference = scaled[7:0];
		end
	endfunction

	always_ff @(posedge clk) begin
		if (reset) begin
			selected <= 0;
			start_d <= 1'b0;
			count <= 0;
			data <= 0;
			eoc <= 1;
			busy <= 0;
		end else begin
			start_d <= start;
			if (start && !start_d && !busy) begin
				selected <= channel;
				count <= COUNT_W'(CONVERSION_CYCLES);
				eoc <= 0;
				busy <= 1;
			end else if (ce_adc && busy) begin
				if (count == 1) begin
					data <= apply_reference(analog[selected]);
					count <= 0;
					eoc <= 1;
					busy <= 0;
				end else count <= count - 1'd1;
			end
		end
	end
endmodule
