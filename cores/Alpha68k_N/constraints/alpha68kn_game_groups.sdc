# Isolated check candidate only. Append to core SDC; do not alter pinned sys/.
# Restore the inherited MiSTer group boundary for this core's actual PLL name.
# Both 48 MHz outputs remain in ONE group: game 0ps and SDRAM 10416ps.
set a68n_game_pll_clocks [get_clocks {emu|pll|pll|*|divclk}]
if {[get_collection_size $a68n_game_pll_clocks] != 2} {
    error "Alpha68k N expects exactly two related game/SDRAM PLL outputs"
}
set a68n_framework_patterns [list \
    {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk} \
    {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk} \
    {spi_sck} {hdmi_sck} {*|h2f_user0_clk} \
    {FPGA_CLK1_50} {FPGA_CLK2_50} {FPGA_CLK3_50}]
foreach a68n_pattern $a68n_framework_patterns {
    set a68n_framework_clock [get_clocks $a68n_pattern]
    if {[get_collection_size $a68n_framework_clock] != 1} {
        error "Alpha68k N expected one existing framework clock for $a68n_pattern"
    }
    # Pair only the missing game group with each existing framework group.
    # Existing framework-to-framework exceptions are left as inherited.
    set_clock_groups -asynchronous \
        -group $a68n_game_pll_clocks -group $a68n_framework_clock
}
unset a68n_game_pll_clocks
unset a68n_framework_patterns
unset a68n_pattern
unset a68n_framework_clock
