derive_pll_clocks
derive_clock_uncertainty

# The stock hierarchy contains pll_inst, while this owned PLL does not. The
# system/forwarded-SDRAM clocks stay related. These independent platform
# families retain their existing framework clock-domain crossing contract.
set penguin_core_clocks [get_clocks {emu|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $penguin_core_clocks] != 2} {
    error "Penguin expected two related 100 MHz master/I/O clocks"
}
set penguin_platform_clocks [get_clocks {pll_hdmi* pll_audio* spi_sck hdmi_sck *h2f_user0_clk}]
set_clock_groups -asynchronous -group $penguin_core_clocks -group $penguin_platform_clocks

# Core phase and timer enables are synchronous to the 100 MHz system clock.
# They are not separate clocks and have no blanket multicycle exceptions.
#
# External SDRAM timing is an unresolved qualification gate. Registering this
# SDC does not qualify the interface. See docs/timing-constraints.md for the
# generated-clock hierarchy audit and required module/board delay evidence.
