`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Board-local ordinary peripherals.  Quad-POKEY is composed by irobot_core so
// this block remains focused on ADC0809/X2212 and is directly testable with
// the project's SystemVerilog-only Verilator lane.
module irobot_peripherals (
	input  logic       clk_12m096,
	input  logic       reset,
	input  logic       nvram_cs,
	input  logic       nvram_we,
	input  logic [7:0] bus_addr,
	input  logic [3:0] nvram_din,
	input  logic       adc_start,
	input  logic [1:0] adc_channel,
	input  logic [7:0] stick_x,
	input  logic [7:0] stick_y,
	input  logic       nvram_recall,
	input  logic       nvram_store,
	input  logic       nvram_host_we,
	input  logic [7:0] nvram_host_addr,
	input  logic [3:0] nvram_host_din,
	output logic [3:0] nvram_host_dout,
	output logic [7:0] nvram_dout,
	output logic [7:0] adc_dout,
	output logic       adc_eoc,
	output logic       adc_busy,
	output logic       nvram_busy,
	output logic       ce_pokey
);
	logic [3:0] divider;
	// The controls adapter exposes the desired ADC code, while the physical
	// ADC input is a rail voltage.  Keep that boundary explicit and use 12 bits
	// here so the corrected 1.038..3.962 V reference window does not skip codes
	// merely because a host joystick was quantised to eight bits.
	localparam integer ADC_ANALOG_WIDTH = 12;
	localparam integer ADC_VREF_LOW = 850;   // round(4095 * 1.0377 / 5.0)
	localparam integer ADC_VREF_HIGH = 3248; // round(4095 * 3.9623 / 5.0)
	localparam integer ADC_VREF_SPAN = ADC_VREF_HIGH - ADC_VREF_LOW;
	localparam integer ADC_CENTER_RAIL_INT = ADC_VREF_LOW +
		(((8'h80 * ADC_VREF_SPAN) + 254) / 255);
	localparam logic [ADC_ANALOG_WIDTH-1:0] ADC_CENTER_RAIL =
		ADC_ANALOG_WIDTH'(ADC_CENTER_RAIL_INT);
	logic [ADC_ANALOG_WIDTH-1:0] analog_reg [0:7];
	logic [3:0] nv_nibble;

	function automatic [ADC_ANALOG_WIDTH-1:0] code_to_rail(input logic [7:0] code);
		integer delta;
		begin
			// Choose the smallest rail code whose ADC transfer rounds down to
			// the requested digital code.  This is the exact inverse of the
			// integer transfer in adc0809 for every 0..255 endpoint.
			delta = ((code * ADC_VREF_SPAN) + 254) / 255;
			code_to_rail = ADC_ANALOG_WIDTH'(ADC_VREF_LOW + delta);
		end
	endfunction

	// The physical ADC input is a held analog voltage during conversion. Keep
	// that sample as a CPU-domain register so the calibrated code-to-rail divide
	// is not placed in the same cycle as the ADC reference divide at EOC. The
	// ADC conversion is 64 /16 enables (1024 CPU clocks), so this one-clock
	// sample latency is unobservable at the board interface.
	always_ff @(posedge clk_12m096) begin
		if (reset) begin
			for (integer n=0; n<8; n=n+1) analog_reg[n] <= ADC_CENTER_RAIL;
		end else begin
			// SP-251/MAME wiring: ADC0809 AN0 is the Y potentiometer and
			// AN1 is the reversed X potentiometer. The CPU selects these
			// channels through the 1B00-1B03 mirror. Other channels remain
			// centred.
			analog_reg[0] <= code_to_rail(stick_y);
			analog_reg[1] <= code_to_rail(stick_x);
		end
	end

	always_ff @(posedge clk_12m096) begin
		if (reset) divider <= 0;
		else divider <= divider + 1'd1;
	end
	assign ce_pokey = (divider[2:0] == 3'b111); // 12.096 MHz / 8

	// These 12-bit rail endpoints are the same corrected R84/R85/R86 network as
	// the standalone 8-bit ADC model, expressed before the ADC conversion.
	adc0809 #(.CONVERSION_CYCLES(64), .ANALOG_WIDTH(ADC_ANALOG_WIDTH),
		.VREF_LOW_CODE(ADC_VREF_LOW), .VREF_HIGH_CODE(ADC_VREF_HIGH)) adc (
		.clk(clk_12m096), .reset(reset), .ce_adc(divider == 4'hf),
		.start(adc_start), .channel({1'b0,adc_channel}), .analog(analog_reg),
		.data(adc_dout), .eoc(adc_eoc), .busy(adc_busy)
	);

	x2212 nvram (
		.clk(clk_12m096), .reset(reset), .cs(nvram_cs), .we(nvram_we),
		.addr(bus_addr), .din(nvram_din), .dout(nv_nibble),
		.store(nvram_store), .recall(nvram_recall),
		.host_we(nvram_host_we), .host_addr(nvram_host_addr),
		.host_din(nvram_host_din), .host_dout(nvram_host_dout),
		.busy(nvram_busy)
	);
	assign nvram_dout = {4'hf,nv_nibble};
endmodule
