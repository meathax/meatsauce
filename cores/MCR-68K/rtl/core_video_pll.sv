// Core-owned logic/SDRAM/video PLL. This is separate from MiSTer's vendored
// Quartus 17.0.2-generated SunA8bit PLL used elsewhere in this workspace;
// this is deliberately separate from MiSTer's vendored/reconfigurable HDMI
// PLL, which must remain untouched.
`timescale 1ns/10ps
module core_video_pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);
	core_video_pll_impl pll_inst (
		.refclk(refclk), .rst(rst), .outclk_0(outclk_0),
		.outclk_1(outclk_1), .outclk_2(outclk_2), .locked(locked)
	);
endmodule

module core_video_pll_impl (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);
	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("50.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("50.000000 MHz"),
		.phase_shift1("11500 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("100.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst(rst),
		.outclk({outclk_2, outclk_1, outclk_0}),
		.locked(locked),
		.fboutclk(),
		.fbclk(1'b0),
		.refclk(refclk)
	);
endmodule
