# DFJail: JTFRAME_180SHIFT=0, direct forwarded clk48sh from PLL output1.
# Native baseline01 derives output1 at89.99deg; no phase/frequency is changed.
# This binds the forwarded waveform only; part/PCB min/max IO proof is separate.
set dfjail_sdram_src [get_pins {emu|u_jtframe_emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set dfjail_sdram_port [get_ports SDRAM_CLK]
if {[get_collection_size $dfjail_sdram_src] != 1} {
    error "DFJail SDRAM source cardinality must be1, got [get_collection_size $dfjail_sdram_src]"
}
if {[get_collection_size $dfjail_sdram_port] != 1} {
    error "DFJail SDRAM_CLK port cardinality must be1, got [get_collection_size $dfjail_sdram_port]"
}
# Quartus17 get_clocks has no -of_objects option; use the exact native name.
# https://resources.altera.com/quartushelp/17.0/tafs/tafs/tcl_pkg_sdc_ver_1.5_cmd_get_clocks.htm
set dfjail_sdram_source_clocks [get_clocks {emu|u_jtframe_emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $dfjail_sdram_source_clocks] != 1} {
    error "DFJail forwarded source must carry exactly1 derived clock"
}
foreach_in_collection dfjail_clock $dfjail_sdram_source_clocks {
    post_message -type info "DFJail forwarded source [get_clock_info -name $dfjail_clock], period [get_clock_info -period $dfjail_clock], waveform [get_clock_info -waveform $dfjail_clock]"
}
create_generated_clock -name SDRAM_CLK -source $dfjail_sdram_src -divide_by 1 $dfjail_sdram_port
derive_clock_uncertainty
