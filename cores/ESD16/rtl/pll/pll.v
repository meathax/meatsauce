// Core PLL wrapper: 50 MHz -> clk_sys 64 MHz (outclk_0) and SDRAM_CLK 64 MHz delayed (outclk_1).
// Instance names keep the Template hierarchy (emu|pll|pll_inst|altera_pll_i) matched by sys_top.sdc.
module pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
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
