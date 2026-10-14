derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# Core specific constraints
#
# Ikki runs entirely from one 40 MHz PLL output.  Ikki.sv ties clk_sys to
# clk_vid, so the CPUs, the renderer and the PSGs share a single clock domain
# and every internal transfer is synchronous; there are no core-internal
# clock-domain crossings to constrain or false-path.
#
# sys/sys.tcl already cuts the paths between this domain and the framework
# clocks (FPGA_CLK*, pll_hdmi, pll_audio, h2f_user0_clk).
# ---------------------------------------------------------------------------

set core_clk [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

if {[get_collection_size $core_clk] > 0} {
	# The unused 98.304 MHz PLL output drives nothing; keep it from being
	# reported as an unconstrained or failing domain.
	set mem_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
	if {[get_collection_size $mem_clk] > 0} {
		set_false_path -from $mem_clk -to $core_clk
		set_false_path -from $core_clk -to $mem_clk
	}
}
