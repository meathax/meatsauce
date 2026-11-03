`timescale 1ns/10ps
// Exterminator clock trio, same altera_pll structure as donors/NARC
// (rtl/pll/synthesis/submodules/pll_pll_inst.v: 96.648 / 24.162 / 96.648 MHz@180deg).
//
//   refclk   50 MHz  (CLK_50M)
//   outclk0  80 MHz  clk_ram   : SDRAM controller domain          (VCO 800 MHz / 10)
//   outclk1  20 MHz  clk_sys   : whole game core, CLK_VIDEO        (VCO 800 MHz / 40)
//   outclk2  80 MHz  SDRAM_CLK : clk_ram phase shifted +256.5 deg  (8906 ps = 57 VCO/8 steps of 156.25 ps)
//
// VCO = 50 MHz x 16 = 800 MHz (Cyclone V fPLL range 600..1300 MHz), integer-N,
// no fractional mode.  clk_sys is an exact 1:4 divide of clk_ram from the same
// VCO, so the two domains are phase aligned (as in NARC).
// Retain the 8906 ps forwarded-clock phase; the corrected controller samples
// CL2 at E3 and consumes that registered sample at E4. Qualify the actual
// command-to-pad/data-to-input edges in each new fit, including BL1 release.
module pll_pll_inst(
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
		.output_clock_frequency0("80.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("20.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("80.000000 MHz"),
		.phase_shift2("8906 ps"),
		.duty_cycle2(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);

endmodule
