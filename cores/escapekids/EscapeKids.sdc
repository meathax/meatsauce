# EscapeKids uses the JTFRAME compatibility wrapper, whose fitted main PLL
# hierarchy is different from the historical Template_MiSTer wildcard in
# sys/sys_top.sdc. Keep the original framework SDC untouched and add the
# exact fitted clock groups here. The game domains are all synchronous enables
# of the main 48 MHz PLL; these groups only separate independent framework
# PLLs and root clocks as intended by the Template contract.
derive_pll_clocks
derive_clock_uncertainty

# JOY_CLK is JCLOCKS[3] in the active DB15 divider: 48 MHz / 16 = 3 MHz.
# Target the fitted register as a keeper; a bare register name is not a pin.
set joy_db15_source [get_pins {emu|u_jtframe|pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set joy_db15_target [get_keepers {emu:emu|escape_kids_jtframe_emu:u_jtframe|jtframe_mister:u_frame|jtframe_joymux:u_joymux|joy_db15:u_db15|JCLOCKS[3]}]
if { [get_collection_size $joy_db15_source] != 1 } {
    error "Expected exactly one JTFRAME DB15 serializer source clock pin"
}
if { [get_collection_size $joy_db15_target] != 1 } {
    error "Expected exactly one JTFRAME DB15 serializer JCLOCKS[3] keeper"
}
create_generated_clock -name joy_db15_clk -source $joy_db15_source -divide_by 16 $joy_db15_target

set_clock_groups -exclusive \
    -group [get_clocks {emu|u_jtframe|pll|u_pll|*PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter*output_counter|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general*PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# ---------------------------------------------------------------------------
# SDRAM interface timing (previously unconstrained: TimeQuest never analyzed
# any SDRAM pin path in this project; upstream jtframe ships an equivalent
# sdram_clk48.sdc generated clock for its own builds).
# The board clock is the PLL's shifted 48 MHz output (general[1]) driven out
# on the SDRAM_CLK pin; the SDRAM chip launches/captures at that clock while
# the controller launches/captures at the unshifted 48 MHz (general[0]).
# (JTFRAME_180SHIFT=1 would move this to an inverted DDIO-driven clock; that
# configuration misses SDRAM output setup by ~2 ns and is not used.)
set sdram_clk_src [get_pins {emu|u_jtframe|pll|u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if { [get_collection_size $sdram_clk_src] != 1 } {
    error "Expected exactly one shifted-48MHz PLL output pin for SDRAM_CLK"
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 [get_ports {SDRAM_CLK}]

# AS4C32M16SB / W9825G6KH class, CL2, -6/-7 grade, conservative values.
# Inputs: data valid tAC(max)=6.0 ns after SDRAM_CLK, held tOH(min)=2.7 ns.
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.7 [get_ports {SDRAM_DQ[*]}]

# Outputs: chip needs tIS=1.5 ns setup, tIH=0.8 ns hold at SDRAM_CLK.
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -max 1.5  $sdram_outs
set_output_delay -clock SDRAM_CLK -min -0.8 $sdram_outs
