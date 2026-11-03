derive_pll_clocks
derive_clock_uncertainty

# The forwarding DDIO clock pin is driven by the dedicated related PLL PHY
# output. Binding there avoids guessing generated counter names/indexes.
set spy_clock_pin [get_pins -compatibility_mode {*|u_sdram_clock|*|muxsel}]
if {[get_collection_size $spy_clock_pin] != 1} {
    error "S.P.Y. forwarding DDIO clock must resolve to one fitted pin"
}
create_generated_clock -name spy_sdram_forward -source $spy_clock_pin -divide_by 1 [get_ports SDRAM_CLK]
set spy_related_clocks [get_clocks {*|u_clock|u_pll|*|divclk}]
if {[get_collection_size $spy_related_clocks] != 2} {
    error "S.P.Y. must expose both related48MHz PLL output clocks"
}

# Unchanged Template sys/sys_top.sdc identifies its core by the donor hierarchy
# *|pll|pll_inst|altera_pll_i|*[*].*|divclk. Our direct PLL wrapper has a different
# hierarchy and was omitted. Extend the same existing system-domain grouping.
# Source file SHA256: 0a5fa4015b82ad7ce38e56d1ae4aadea6209af59c5dd9eff56a11139cf16ce86.
set_clock_groups -exclusive \
    -group [get_clocks {*|u_clock|u_pll|*|divclk spy_sdram_forward}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# Standard MiSTer module envelope (scripts/mra/sdram-envelope.json): CL2
# tAC<=6.5ns, tOH>=2.5ns, tIS=1.5ns, tIH=0.8ns. Allow clock+return flight
# [0,2]ns, command/data-vs-clock skew +/-1ns and additional external margin0.5ns.
# These are conservative interface budgets, not measured user-board delays.
set spy_sdram_dq [get_ports {SDRAM_DQ[*]}]
set spy_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_nWE SDRAM_nRAS SDRAM_nCAS SDRAM_nCS SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
if {[get_collection_size $spy_sdram_dq] != 16 || [get_collection_size $spy_sdram_outputs] != 38} {
    error "S.P.Y. SDRAM pin constraints must cover16 DQ and38 command/address/data outputs"
}
set_input_delay -clock spy_sdram_forward -max 9.0 $spy_sdram_dq
set_input_delay -clock spy_sdram_forward -min 2.0 $spy_sdram_dq
set_output_delay -clock spy_sdram_forward -max 3.0 $spy_sdram_outputs
set_output_delay -clock spy_sdram_forward -min -2.3 $spy_sdram_outputs
