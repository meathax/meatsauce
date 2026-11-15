# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode spi|sclk_out] -name spi_sck
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty


# Diagnostic: all inherited exceptions removed to expose the actual transfer graph.

source current_packets.tcl
set ::seicro_hpsdiag_root_name [get_clock_info -name [get_clocks {*emu|pll*general?0?*PLL_OUTPUT_COUNTER*divclk}]]
source seicro_hpsdiag_hps_affinity.tcl
