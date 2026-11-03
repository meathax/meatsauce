derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

set_false_path -from [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] -to [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]

set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]

create_generated_clock -name clk_3M -source [get_nets {emu|pll|pll_inst|altera_pll_i|outclk_wire[0]}] -divide_by 24 [get_nets {emu|clk_3M}]

# create_clock -name clk_4M -period "4.0 MHz" [get_nets {emu|clk_4M}]
create_generated_clock -name clk_4M -source [get_nets {emu|pll|pll_inst|altera_pll_i|outclk_wire[0]}] -divide_by 18 [get_nets {emu|clk_4M}]

# create_clock -name clk_6M -period "6.0 MHz" [get_nets {emu|clk_6M}]
create_generated_clock -name clk_6M -source [get_nets {emu|pll|pll_inst|altera_pll_i|outclk_wire[0]}] -divide_by 12 [get_nets {emu|clk_6M}]

# ---- SDRAM interface (forwarded clock, board budgets, proved input edge pair) ----
# Kept in this file so it is evaluated after derive_pll_clocks above, independent of SDC file order.
# Inherited from the Search and Rescue repair (same 72MHz/-4513ps CL2/BL2 controller).
# CL2/BL2 profile, Micron MT48LC16M16A2 RevD/Table12:
# tAC<=7.5ns, tOH>=1.8ns, tIS1.5ns and tIH0.8ns.
# Bounded assumptions: <=1ns outbound clock and <=1ns return data flight;
# minimum flight0; output clock/data skew<=0.5ns. These are not board measurements.
# SDRAM_CLK directly forwards PLL output1 (72MHz,-4513ps), without inversion.
set ts_sdram_master {}
set ts_capture_master {}
foreach_in_collection c [get_clocks *] {
    set n [get_clock_info -name $c]
    if {$n eq {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}} {set ts_capture_master $n}
    # Exact target identity from this project's native routed clock report.
    if {$n eq {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}} {
        if {$ts_sdram_master ne {}} {error {Multiple Time Soldiers SDRAM masters}}
        set ts_sdram_master $n
    }
}
if {$ts_sdram_master eq {}} {error {Missing Time Soldiers SDRAM master}}
if {$ts_capture_master eq {}} {error {Missing related Time Soldiers capture clock}}
set ts_sdram_source [get_pins -compatibility_mode $ts_sdram_master]
if {[get_collection_size $ts_sdram_source] != 1} {error {Time Soldiers SDRAM source must resolve once}}
create_generated_clock -name ts_sdram_clk -source $ts_sdram_source \
    -master_clock $ts_sdram_master -divide_by 1 [get_ports SDRAM_CLK]
set ts_sdram_dq [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $ts_sdram_dq] != 16} {error {Time Soldiers SDRAM must have16 DQ ports}}
set ts_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $ts_sdram_outputs] != 38} {error {Time Soldiers SDRAM must have38 output/bidir ports}}
set_output_delay -clock ts_sdram_clk -max 2.0 $ts_sdram_outputs
set_output_delay -clock ts_sdram_clk -min -1.3 -add_delay $ts_sdram_outputs
set_input_delay -clock ts_sdram_clk -max 9.5 $ts_sdram_dq
set_input_delay -clock ts_sdram_clk -min 1.8 -add_delay $ts_sdram_dq
set ts_sdram_capture [get_registers {*|sdram|sampled_data[*]}]
if {[get_collection_size $ts_sdram_capture] != 16} {error {Time Soldiers SDRAM capture must resolve16 endpoints}}
set ts_sdram_bridge [get_registers {*|sdram|captured_pos[*]}]
set ts_bridge_bits [dict create]
foreach_in_collection r $ts_sdram_bridge {
    set name [get_node_info -name $r]
    if {![regexp {captured_pos\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name unused bit suffix] || $bit>15} {error "Unexpected bridge endpoint: $name"}
    dict set ts_bridge_bits $bit 1
}
if {[dict size $ts_bridge_bits]!=16} {error {Missing logical SDRAM bridge bits}}
# The physical input captures the PRECEDING CL2/BL2 word after the following
# external clock edge, while its guaranteed tOH/return window still owns it.
# TimeQuest17 edge review98fd09be: setup launch9.375->capture26.387;
# next-word hold launch9.375->capture12.499 (normalized by one period).
# Setup2/hold1 instead checks launch23.263->capture12.499 and misses that word.
# Only the16 physical pin captures get this proved2/0 pair. Local half-cycle
# and coherent bridge-to-SYS publication remain ordinary fully timed paths.
set_multicycle_path -setup -end 2 -from $ts_sdram_dq -to $ts_sdram_capture
set_multicycle_path -hold -end 0 -from $ts_sdram_dq -to $ts_sdram_capture
derive_clock_uncertainty
