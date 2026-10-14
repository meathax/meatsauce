derive_pll_clocks
derive_clock_uncertainty

# All game logic is synchronous to the 49.152 MHz PLL output. CPU and pixel
# rates are clock enables, not derived clocks, so no internal CDC exceptions
# are required. sys/sys.tcl supplies framework-domain constraints.
set core_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $core_clk] > 0} {
	set unused0 [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
	set unused2 [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
	if {[get_collection_size $unused0] > 0} { set_false_path -from $unused0 -to $core_clk; set_false_path -from $core_clk -to $unused0 }
	if {[get_collection_size $unused2] > 0} { set_false_path -from $unused2 -to $core_clk; set_false_path -from $core_clk -to $unused2 }
}
