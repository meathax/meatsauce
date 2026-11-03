# Action Hollywood: 48 MHz game clock, 96 MHz SDRAM controller clock, forwarded SDRAM pin clock.
# sys/sys_top.sdc owns platform roots/clocks/standard exceptions; keep sys frozen.
derive_pll_clocks

set ah_clk48_pin  [get_pins -compatibility_mode {emu|clock_source|pll_i|general[0].gpll*|divclk}]
set ah_clk96_pin  [get_pins -compatibility_mode {emu|clock_source|pll_i|general[1].gpll*|divclk}]
set ah_fwd_pin    [get_pins -compatibility_mode {emu|clock_source|pll_i|general[2].gpll*|divclk}]
foreach ah_c {ah_clk48_pin ah_clk96_pin ah_fwd_pin} {
    if {[get_collection_size [set $ah_c]] != 1} { error "Action Hollywood: expected exactly one PLL output for $ah_c" }
}
set ah_sdram_pin [get_ports {SDRAM_CLK}]
if {[get_collection_size $ah_sdram_pin] != 1} { error "Action Hollywood: SDRAM clock pin missing" }
create_generated_clock -name ah_sdram_pin -source $ah_fwd_pin -divide_by 1 $ah_sdram_pin

# ISSI IS42S16160G -6/-7, CL3: tAC=5.4, tOH=2.7, setup=1.5, hold=0.8 ns.
# Qualification envelope: clock and each data/control board path 0..0.5 ns (the user's SDRAM module is not identified).
# Read round trip: max=0.5+5.4+0.5=6.4; min=0+2.7+0=2.7.   Write relative skew: max=1.5+0.5=2.0; min=-0.8-0.5=-1.3.
set ah_dq [get_ports {SDRAM_DQ[*]}]
set ah_outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $ah_dq] != 16 || [get_collection_size $ah_outputs] != 38} {
    error "Action Hollywood SDRAM timing port closure is incomplete"
}
set_input_delay  -clock ah_sdram_pin -max 6.4 $ah_dq
set_input_delay  -clock ah_sdram_pin -min 2.7 $ah_dq
set_output_delay -clock ah_sdram_pin -max 2.0 $ah_outputs
set_output_delay -clock ah_sdram_pin -min -1.3 $ah_outputs

# The three game clocks and the forwarded pin clock are one synchronous family (same PLL, integer related):
# one clock group keeps every 48<->96 transfer and every SDRAM pin check timed.
set ah_game_clocks [get_clocks {emu|clock_source|pll_i|*|divclk ah_sdram_pin}]
if {[get_collection_size $ah_game_clocks] != 4} {
    error "Action Hollywood master/96 MHz/forwarded clock relationship missing: [get_collection_size $ah_game_clocks]"
}
set_clock_groups -exclusive \
    -group $ah_game_clocks \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]
# Input capture beat: forwarded pin clock phase +4948 ps (= -5.4 ns, window centre from fitted STA: data valid window
# at the pad registers is [pin latency+tAC_max, pin latency+period+tOH_min]) puts the data one core edge after the
# nominal one.  Same-PLL family, integer related: setup N=2 / hold N-1=1 from the pin clock to the 16 pad registers only.
set ah_dq_q [get_registers {*ah_sdram:sdram|dq_q[*]}]
if {[get_collection_size $ah_dq_q] != 16} { error "Action Hollywood dq_q capture registers: [get_collection_size $ah_dq_q]" }
set_multicycle_path -setup -end -from [get_clocks ah_sdram_pin] -to $ah_dq_q 2
set_multicycle_path -hold  -end -from [get_clocks ah_sdram_pin] -to $ah_dq_q 1
derive_clock_uncertainty
