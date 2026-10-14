# SDRAM_CLK is driven directly by the PLL's phase-shifted 48 MHz output
# (outclk_1 = clk48sh = general[1]) — jtframe's exact config for cninja
# (JTFRAME_180SHIFT=0). Define it as a generated clock on the SDRAM_CLK pin.
create_generated_clock -name SDRAM_CLK -source \
    [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 \
    [get_ports SDRAM_CLK]
