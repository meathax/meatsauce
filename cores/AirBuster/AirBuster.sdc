# Air Buster: 48 MHz game clock and the actual forwarded SDRAM clock pin.
# sys/sys_top.sdc owns platform roots/clocks/standard exceptions; keep sys frozen.
derive_pll_clocks

set ab_master_pin [get_pins -compatibility_mode {emu|clock_source|pll_i|general[0].gpll*|divclk}]
if {[get_collection_size $ab_master_pin] != 1} {
    error "Air Buster requires exactly one 48 MHz game PLL output"
}
set ab_sdram_pin [get_ports {SDRAM_CLK}]
if {[get_collection_size $ab_sdram_pin] != 1} {
    error "Air Buster SDRAM clock pin missing"
}
# A second coherent PLL output advances forwarding from the failing 180-degree
# implementation. DDIO is non-inverting; the physical port includes its delay.
set ab_forward_pin [get_pins -compatibility_mode {emu|clock_source|pll_i|general[1].gpll*|divclk}]
if {[get_collection_size $ab_forward_pin] != 1} {
    error "Air Buster requires exactly one coherent SDRAM forwarding PLL output"
}
create_generated_clock -name ab_sdram_pin -source $ab_forward_pin -divide_by 1 $ab_sdram_pin

# ISSI IS42S16160G -6/-7, CL3: tAC=5.4, tOH=2.7, setup=1.5, hold=0.8 ns.
# Qualification envelope: clock and each data/control board path 0..0.5 ns.
# Read round trip: max=0.5+5.4+0.5=6.4; min=0+2.7+0=2.7.
# Write relative skew: max=1.5+0.5-0=2.0; min=-0.8+0-0.5=-1.3.
# This envelope is explicit; the user's actual SDRAM module is not identified.
set ab_dq [get_ports {SDRAM_DQ[*]}]
set ab_outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $ab_dq] != 16 || [get_collection_size $ab_outputs] != 38} {
    error "Air Buster SDRAM timing port closure is incomplete"
}
set_input_delay -clock ab_sdram_pin -max 6.4 $ab_dq
set_input_delay -clock ab_sdram_pin -min 2.7 $ab_dq
set_output_delay -clock ab_sdram_pin -max 2.0 $ab_outputs
set_output_delay -clock ab_sdram_pin -min -1.3 $ab_outputs

# The custom master PLL name is outside the template's generic game-PLL
# pattern. Give master + forwarded pin the same platform clock-group policy.
# Both remain in ONE synchronous group, preserving all SDRAM read/write checks.
set ab_game_clocks [get_clocks {emu|clock_source|pll_i|*|divclk ab_sdram_pin}]
if {[get_collection_size $ab_game_clocks] != 3} {
    error "Air Buster master/forwarded clock relationship missing"
}
set_clock_groups -exclusive \
    -group $ab_game_clocks \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]
derive_clock_uncertainty
