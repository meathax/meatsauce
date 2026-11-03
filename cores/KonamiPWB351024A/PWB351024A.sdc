derive_pll_clocks
derive_clock_uncertainty

# The forwarding DDIO clock pin is driven by the dedicated related PLL PHY
# output. Binding there avoids guessing generated counter names/indexes.
set pwb_clock_pin [get_pins -compatibility_mode {*|u_sdram_clock|*|muxsel}]
if {[get_collection_size $pwb_clock_pin] != 1} {
    error "PWB351024A forwarding DDIO clock must resolve to one fitted pin"
}
create_generated_clock -name pwb_sdram_forward -source $pwb_clock_pin -divide_by 1 [get_ports SDRAM_CLK]
set pwb_related_clocks [get_clocks {*|u_clock|u_pll|*|divclk}]
if {[get_collection_size $pwb_related_clocks] != 2} {
    error "PWB351024A must expose both related48MHz PLL output clocks"
}

# Unchanged Template sys/sys_top.sdc identifies its core by the donor hierarchy
# *|pll|pll_inst|altera_pll_i|*[*].*|divclk. Our direct PLL wrapper has a different
# hierarchy and was omitted. Extend the same existing system-domain grouping.
# Source file SHA256: 0a5fa4015b82ad7ce38e56d1ae4aadea6209af59c5dd9eff56a11139cf16ce86.
set_clock_groups -exclusive \
    -group [get_clocks {*|u_clock|u_pll|*|divclk pwb_sdram_forward}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# Standard MiSTer module envelope (donors/framework/sdram-interface-envelope.json): CL2
# tAC<=6.5ns, tOH>=2.5ns, tIS=1.5ns, tIH=0.8ns. Allow clock+return flight
# [0,2]ns, command/data-vs-clock skew +/-1ns and additional external margin0.5ns.
# Final BL2 release has no common tHZ minimum (Alliance Table16), unlike
# intermediate tOH2.5ns: use0+flight_min0-margin0.5=-0.5ns for input hold.
# These are conservative interface budgets, not measured user-board delays.
set pwb_sdram_dq [get_ports {SDRAM_DQ[*]}]
set pwb_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_nWE SDRAM_nRAS SDRAM_nCAS SDRAM_nCS SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
if {[get_collection_size $pwb_sdram_dq] != 16 || [get_collection_size $pwb_sdram_outputs] != 38} {
    error "PWB351024A SDRAM pin constraints must cover16 DQ and38 command/address/data outputs"
}
set_input_delay -clock pwb_sdram_forward -max 9.0 $pwb_sdram_dq
set_input_delay -clock pwb_sdram_forward -min -0.5 $pwb_sdram_dq
set_output_delay -clock pwb_sdram_forward -max 3.0 $pwb_sdram_outputs
set_output_delay -clock pwb_sdram_forward -min -2.3 $pwb_sdram_outputs

# Project override: the inherited destination-wide OSD 2/1 allowance has no
# complete source/capture interval proof. Restore ordinary one-cycle setup and
# same-edge hold on its exact resolved endpoints. Cross-domain false paths still
# take precedence and require a separate coherent-transfer protocol audit.
set pwb_osd_vcnt [get_registers {*_osd|osd_vcnt*}]
if {[get_collection_size $pwb_osd_vcnt] == 0} {
    error "PWB351024A OSD counter endpoint collection must not be empty"
}
set_multicycle_path -to $pwb_osd_vcnt -setup 1
set_multicycle_path -to $pwb_osd_vcnt -hold 0
puts "PWB351024A normal OSD timing endpoints: [get_collection_size $pwb_osd_vcnt]"

# Dedicated held-bundle OSD physical constraints (no new clock/cut).
source rtl/framework/platform/pwb_osd_cdc.sdc

# Scoped proven Q-event operand transfer; strict fitted endpoint guard.
source rtl/framework/platform/pwb_math_timing.sdc

# Source-bound board I/O contracts: actual forwarded clocks and physical transports.
source rtl/framework/platform/pwb_board_io.sdc
