// megafunction wizard: %Altera PLL v17.0%
// Yellow Cab: 48 MHz sys + 96 MHz RAM + phase-shifted SDRAM_CLK
`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   // 50 MHz
		input  wire  rst,
		output wire  outclk_0, // 48 MHz clk_sys
		output wire  outclk_1, // 96 MHz clk_ram
		output wire  outclk_2, // 96 MHz SDRAM_CLK (-60°)
		output wire  locked
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
