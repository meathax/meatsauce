#============================================================================
# DataEastLiberation MiSTer - core timing constraints
#
# sys/sys_top.sdc brings in the platform-level constraints (HPS, HDMI, VGA...).
# This file covers the core clock and the asynchronous control paths into it.
#
# One system clock: 48 MHz (= CLK_VIDEO, 8x the 6 MHz pixel clock, >= every PCB
# clock) with the SDRAM at 96 MHz (2x). Every CPU, MCU, sound chip and video
# stage runs on that clock through clock enables, so there are no derived or
# generated CPU clocks to constrain.
#============================================================================

derive_pll_clocks

# ---------------------------------------------------------------------------
# Asynchronous / quasi-static inputs.
#
# status[], the DIP switches and the ioctl download stream are driven from the
# HPS side and are either static while the core runs or held for many clocks.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*|status[*]}]

# ---------------------------------------------------------------------------
# CPU periods are already represented by their generated clocks. Blanket
# multicycles over the wrappers also relax their 48 MHz divider registers.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Universal-engine timing boundaries.
#
# Only one universal engine is released from reset at a time.  The selector is
# latched before reset release, so paths between mutually exclusive engine
# register banks cannot occur during active operation.
set lib_regs [get_registers {emu:emu|yellowcab_core:u_core|*}]
set bw_regs  [get_registers {emu:emu|bwing_core:u_bwing|*}]
set dc_regs  [get_registers {emu:emu|decocass_core:u_decocass|*}]
set_false_path -from $lib_regs -to $bw_regs
set_false_path -from $lib_regs -to $dc_regs
set_false_path -from $bw_regs  -to $lib_regs
set_false_path -from $bw_regs  -to $dc_regs
set_false_path -from $dc_regs  -to $lib_regs
set_false_path -from $dc_regs  -to $bw_regs
set_false_path -from [get_registers {*|game_engine[*]}] -to $bw_regs
set sw_regs [get_registers {*|sw[*][*]}]
set_false_path -from $sw_regs -to $lib_regs
set_false_path -from $sw_regs -to $bw_regs
set_false_path -from $sw_regs -to $dc_regs

# B-Wings mc6809i includes full-rate falling-edge E/Q history registers.
# Its bus crosses several E/Q phases and full-rate BRAM/cache controls.
# Time these paths normally; a 32-clock bus period is not a path exception.
# See docs/CLOCK_TIMING_AUDIT_2026-10-16.md for source evidence.

# MiSTer platform pins are closed by the board/platform timing contract; this
# project does not have external device delay models for them.  Keep them out
# of the core register-to-register sign-off instead of leaving them as hidden
# unconstrained paths.
set_false_path -from [get_ports {HDMI_I2C_SDA IO_SDA SDCD_SPDIF HDMI_TX_INT SD_SPI_MISO ADC_SDO}]
set_false_path -to [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA HDMI_I2S HDMI_LRCLK HDMI_MCLK HDMI_SCLK HDMI_TX_CLK HDMI_TX_DE HDMI_TX_D[*] HDMI_TX_HS HDMI_TX_VS IO_SCL IO_SDA SDCD_SPDIF SDIO_CLK SDIO_CMD SDIO_DAT[*] }]
# Framework indicators and optional user/SD interfaces use the same platform
# boundary contract. These exceptions cover external pins, never core registers.
set_false_path -to [get_ports {LED[*] SD_SPI_CS USER_IO[*]}]


# SDRAM (AS4C32M16SB, CL2 @ 96 MHz): constrained at the physical clock pin, not false-pathed.
create_generated_clock -name sdram_ck -source [get_pins -compatibility_mode {*pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports SDRAM_CLK]
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_DQML SDRAM_DQMH}]
set_output_delay -clock sdram_ck -max  1.5 $sdram_outs
set_output_delay -clock sdram_ck -min -0.8 $sdram_outs
set_input_delay  -clock sdram_ck -max  6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_ck -min  2.5 [get_ports {SDRAM_DQ[*]}]
# dq_in captures on every controller edge; no delayed-capture exception is proved.
# DQM changes with write byte enables and needs the same pin timing as DQ.
set_false_path -to [get_ports {SDRAM_nCS SDRAM_CKE SDRAM_CLK}]

# sys_top.sdc groups only the PLL outputs, before sdram_ck exists. Keep the
# SDRAM pin clock in its parent group so unrelated HPS, HDMI, audio and board
# oscillators do not acquire artificial edge relationships.
set_clock_groups -asynchronous \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|*[*].*|divclk sdram_ck}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# Derive uncertainty after every generated clock, including the forwarded pin.
derive_clock_uncertainty
