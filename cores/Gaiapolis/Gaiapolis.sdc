# Related48/24/96MHz core clocks retain their real PLL phases. The shifted
# SDRAM96 output is -3906ps and is forwarded through the I/O DDR clock cell.
derive_pll_clocks
set gaiapolis_sdram_clk_src [get_pins {emu|pll|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $gaiapolis_sdram_clk_src] != 1} {error "Missing selected SDRAM forwarding PLL output"}
create_generated_clock -name GAIAPOLIS_SDRAM_CLK -source $gaiapolis_sdram_clk_src -divide_by 1 [get_ports SDRAM_CLK]
# Alliance AS4C16M16SA-6/-7 C&I v3 Table16, CAS2 at96MHz:
# tAC6.0,tOH2.5,tIS1.5,tIH0.8ns. Budget1.0ns PCB round trip and0.5ns
# output data/clock skew. This is a reference module profile, not chip ID.
set_input_delay -clock GAIAPOLIS_SDRAM_CLK -max 7.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock GAIAPOLIS_SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
set gaiapolis_ram_outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock GAIAPOLIS_SDRAM_CLK -max 2.0 $gaiapolis_ram_outputs
set_output_delay -clock GAIAPOLIS_SDRAM_CLK -min -1.3 $gaiapolis_ram_outputs
# Relative to the shifted PLL edge, each word is captured two core edges later.
# That edge is the unchanged JTFRAME DST sample; do not add a controller
# capture cycle for it. Do NOT compensate hold: the next word's earliest
# arrival still must pass, so this continues to check every burst-word window.
set_multicycle_path 2 -setup -from [get_ports {SDRAM_DQ[*]}]

foreach {name pin} {
    GAIAPOLIS_HDMI_NORMAL {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
    GAIAPOLIS_HDMI_DIRECT {emu|pll|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}
} {
    set source [get_pins $pin]
    if {[get_collection_size $source] != 1} {error "Missing HDMI clock source: $pin"}
    set master_name ""
    foreach_in_collection clk [get_clocks *] {
        if {[get_clock_info -name $clk] eq $pin} {set master_name $pin}
    }
    if {$master_name eq ""} {error "Missing HDMI master clock: $pin"}
    # The existing output DDR cell forwards the inverted selected video clock.
    create_generated_clock -name $name -source $source -master_clock $master_name -divide_by 1 -invert -add [get_ports HDMI_TX_CLK]
    # ADV7513 RevB tVSU1.8/tVHLD1.3ns, plus0.5ns board-skew budget.
    set_output_delay -clock $name -max 2.3 -add_delay [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
    set_output_delay -clock $name -min -1.8 -add_delay [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
}
# Reproduce the existing unrelated domain boundaries, extending each parent
# group with its forwarded-clock children. Core48/96 paths remain timed.
remove_clock_groups -all
set_clock_groups -asynchronous \
    -group [get_clocks {*emu|pll|altera_pll_i|*|divclk GAIAPOLIS_SDRAM_CLK GAIAPOLIS_HDMI_DIRECT}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*|divclk GAIAPOLIS_HDMI_NORMAL}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}] \
    -group [get_clocks spi_sck] -group [get_clocks hdmi_sck] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks FPGA_CLK1_50] -group [get_clocks FPGA_CLK2_50] -group [get_clocks FPGA_CLK3_50]
# Add a small internal hold guard band; retain all device-derived uncertainty.
set gaiapolis_internal_clocks [get_clocks {*emu|pll|altera_pll_i|*|divclk}]
set_clock_uncertainty -hold -add 0.050 -from $gaiapolis_internal_clocks -to $gaiapolis_internal_clocks
derive_clock_uncertainty
