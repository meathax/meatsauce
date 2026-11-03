// pll.v -- thin wrapper keeping the NARC hierarchy names (emu|pll|pll_inst|altera_pll_i)
// so the NARC-style SDC pin patterns (*|pll|pll_inst|altera_pll_i|*[N].*|divclk) match.
`timescale 1 ps / 1 ps
module pll (
		output wire  locked_export, //  locked.export
		output wire  outclk0_clk,   // outclk0.clk  80 MHz clk_ram
		output wire  outclk1_clk,   // outclk1.clk  20 MHz clk_sys
		output wire  outclk2_clk,   // outclk2.clk  80 MHz +180 deg -> SDRAM_CLK
		input  wire  refclk_clk,    //  refclk.clk
		input  wire  reset_reset    //   reset.reset
	);

	pll_pll_inst pll_inst (
		.refclk   (refclk_clk),
		.rst      (reset_reset),
		.outclk_0 (outclk0_clk),
		.outclk_1 (outclk1_clk),
		.outclk_2 (outclk2_clk),
		.locked   (locked_export)
	);

endmodule
