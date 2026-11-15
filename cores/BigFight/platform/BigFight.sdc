# clk_sys = CLK_VIDEO = core PLL outclk_0 (50MHz, 0ps) from FPGA_CLK2_50; pixel CE /8.
# The SDRAM controller also runs on clk_sys (1x, CL2). No multicycle,
# false-path or clock-group exception is applied to game or memory paths.
derive_pll_clocks
derive_clock_uncertainty
set bigfight_core_clocks [get_clocks {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
if {[get_collection_size $bigfight_core_clocks] != 1} {
    error "Expected exactly one BigFight core PLL clock (50MHz sys)"
}

# SDRAM I/O (docs/STANDARD_SDRAM_TARGET.md; Alliance AS4C16M16SA -7, CL2/BL4).
# Datasheet table16: tAC(CL2)=6.0ns (CL3=5.4ns); tOH=2.5ns.
# SDRAM_CLK is forwarded through altddio_out with datain_h=0/datain_l=1, i.e.
# the inverse of clk_sys. Commands/DQ out launch on clk_sys rising edges; read
# DQ is captured on clk_sys falling edges (dq_reg). Board flight: 1ns clock,
# 1ns data, applied once each (same envelope as the qualified pin witness).
create_generated_clock -name SDRAM_CLK -invert -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}] [get_ports {SDRAM_CLK}]
set_output_delay -clock SDRAM_CLK -max [expr {1.5 + 1.0 - 1.0}] [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS}]
set_output_delay -clock SDRAM_CLK -min [expr {-0.8 + 0.0 - 1.0}] [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS}]
set_input_delay -clock SDRAM_CLK -max [expr {6.0 + 1.0 + 1.0}] [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min [expr {2.5 + 0.0}] [get_ports {SDRAM_DQ[*]}]

# The inherited platform grants OSD osd_vcnt a 2/1 multicycle. Restore the
# normal single-cycle contract in this core rather than relying on that CE
# assumption. All 44 fitted capture registers passed setup/hold at every
# operating corner with this stricter requirement (osd-single-cycle-20261023T204721Z-da4d6f2c).
set bigfight_osd_counters [get_registers {*_osd|osd_vcnt*}]
if {[get_collection_size $bigfight_osd_counters] == 0} {
    error "Expected inherited OSD counter registers for single-cycle timing"
}
set_multicycle_path -setup 1 -to $bigfight_osd_counters
set_multicycle_path -hold 0 -to $bigfight_osd_counters
