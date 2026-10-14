derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# SDRAM interface. OSMAN.sv forwards PLL outclk_1 (clk_sys + 5215 ps) through a
# DDIO cell to SDRAM_CLK. Datasheet: Alliance AS4C32M16SB-7, CL2: tAC 6.0,
# tOH 2.5, tIS 1.5, tIH 0.8 ns. Board: up to 0.5 ns per trace; clock/command
# traces treated as matched +-0.3 ns. Default edge relationships are the RTL
# intent: commands latch on the next chip edge, CL2 data on the next clk_sys edge.
set sdram_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name SDRAM_CLK -source $sdram_src -divide_by 1 [get_ports SDRAM_CLK]
set sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -max  1.8 $sdram_out
set_output_delay -clock SDRAM_CLK -min -1.1 $sdram_out
set_input_delay  -clock SDRAM_CLK -max  7.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min  2.5 [get_ports {SDRAM_DQ[*]}]

# Board I/O coverage; receiver requirements and protocol assumptions are
# documented in docs/BOARD_TIMING.md. Preserve the pinned sys/ constraints.
# ADV7513 video setup/hold: 1.8/1.3 ns, with +/-0.3 ns matched trace skew.
# The framework's DDIO forwards an inverted clock in both video modes.
set hdmi_scaled_src [get_pins {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set hdmi_direct_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name HDMI_TX_SCALED -source $hdmi_scaled_src -divide_by 1 -invert [get_ports HDMI_TX_CLK]
create_generated_clock -name HDMI_TX_DIRECT -source $hdmi_direct_src -divide_by 1 -invert -add [get_ports HDMI_TX_CLK]
set_clock_groups -logically_exclusive \
    -group [get_clocks {HDMI_TX_SCALED pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    -group [get_clocks {HDMI_TX_DIRECT emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set hdmi_data_ports [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
foreach hdmi_clock {HDMI_TX_SCALED HDMI_TX_DIRECT} {
    set_output_delay -clock $hdmi_clock -max 2.1 -add_delay $hdmi_data_ports
    set_output_delay -clock $hdmi_clock -min -1.6 -add_delay $hdmi_data_ports
}
# Asynchronous external entries: HPS I2C, GPIO expander I2C, HDMI event IRQ,
# and card-detect feedback on the shared SPDIF pad.
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT IO_SDA SDCD_SPDIF}]
# These status LEDs have no clocked external receiver.
set_false_path -to [get_ports {LED[0] LED[2] LED[6]}]
# Only the analog VGA branches of the shared SD pads are excluded. Digital
# SPI comes from the HPS hard peripheral rather than either video clock.
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    -to [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS}]
# Bound serial/forwarded-clock pin propagation without assigning a fixed
# phase to reset-dependent audio dividers or self-clocked/open-drain outputs.
set auxiliary_outputs [get_ports {HDMI_TX_CLK HDMI_MCLK HDMI_SCLK HDMI_LRCLK HDMI_I2S HDMI_I2C_SCL HDMI_I2C_SDA IO_SCL IO_SDA SDCD_SPDIF USER_IO[2] USER_IO[4] USER_IO[5]}]
set_max_delay 20.0 -to $auxiliary_outputs
set_min_delay 0.0 -to $auxiliary_outputs
