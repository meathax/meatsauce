# Existing hardware: 72MHz PLL fabric and registered one-cycle divider pulses.
# No frequencies, phases, enables or video cadence are changed by this SDC.
# Each generated clock is a real event-control clock in the legacy core.
# -edges preserves the one-clk_sys high pulse; divide_by alone implies 50% duty.
set snk68_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $snk68_source] != 1} {error "snk68: expected one fabric PLL pin"}
foreach {snk68_name snk68_div} {clk_4M 18 clk_6M 12 clk_18M 4} {
    set snk68_target [get_registers "*|$snk68_name"]
    if {[get_collection_size $snk68_target] != 1} {error "snk68: expected one $snk68_name register"}
    create_generated_clock -name $snk68_name -source $snk68_source -edges [list 1 3 [expr {2*$snk68_div+1}]] $snk68_target
}
# clk_18M pause may stretch a high or low interval; the minimum rising spacing
# remains four clk_sys periods. All its consumers use rising edges.
# No CDC, asynchronous reset, SDRAM I/O or data-path exceptions are added here.
