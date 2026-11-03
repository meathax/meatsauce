# CL2/BL2 profile, Micron MT48LC16M16A2 RevD/Table12:
# tAC<=7.5ns, tOH>=1.8ns, tIS1.5ns and tIH0.8ns.
# Bounded assumptions: <=1ns outbound clock and <=1ns return data flight;
# minimum flight0; output clock/data skew<=0.5ns. These are not board measurements.
# SDRAM_CLK directly forwards PLL output1 (72MHz,-4513ps), without inversion.
set sar_sdram_master {}
set sar_capture_master {}
foreach_in_collection c [get_clocks *] {
    set n [get_clock_info -name $c]
    if {$n eq {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}} {set sar_capture_master $n}
    # Exact target identity from this project's native routed clock report.
    if {$n eq {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}} {
        if {$sar_sdram_master ne {}} {error {Multiple SAR SDRAM masters}}
        set sar_sdram_master $n
    }
}
if {$sar_sdram_master eq {}} {error {Missing SAR SDRAM master}}
if {$sar_capture_master eq {}} {error {Missing related SAR capture clock}}
set sar_sdram_source [get_pins -compatibility_mode $sar_sdram_master]
if {[get_collection_size $sar_sdram_source] != 1} {error {SAR SDRAM source must resolve once}}
create_generated_clock -name sar_sdram_clk -source $sar_sdram_source \
    -master_clock $sar_sdram_master -divide_by 1 [get_ports SDRAM_CLK]
set sar_sdram_dq [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $sar_sdram_dq] != 16} {error {SAR SDRAM must have16 DQ ports}}
set sar_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $sar_sdram_outputs] != 38} {error {SAR SDRAM must have38 output/bidir ports}}
set_output_delay -clock sar_sdram_clk -max 2.0 $sar_sdram_outputs
set_output_delay -clock sar_sdram_clk -min -1.3 -add_delay $sar_sdram_outputs
set_input_delay -clock sar_sdram_clk -max 9.5 $sar_sdram_dq
set_input_delay -clock sar_sdram_clk -min 1.8 -add_delay $sar_sdram_dq
set sar_sdram_capture [get_registers {*|sdram|sampled_data[*]}]
if {[get_collection_size $sar_sdram_capture] != 16} {error {SAR SDRAM capture must resolve16 endpoints}}
set sar_sdram_bridge [get_registers {*|sdram|captured_pos[*]}]
set sar_bridge_bits [dict create]
foreach_in_collection r $sar_sdram_bridge {
    set name [get_node_info -name $r]
    if {![regexp {captured_pos\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name unused bit suffix] || $bit>15} {error "Unexpected bridge endpoint: $name"}
    dict set sar_bridge_bits $bit 1
}
if {[dict size $sar_bridge_bits]!=16} {error {Missing logical SDRAM bridge bits}}
# The physical input captures the PRECEDING CL2/BL2 word after the following
# external clock edge, while its guaranteed tOH/return window still owns it.
# TimeQuest17 edge review98fd09be: setup launch9.375->capture26.387;
# next-word hold launch9.375->capture12.499 (normalized by one period).
# Setup2/hold1 instead checks launch23.263->capture12.499 and misses that word.
# Only the16 physical pin captures get this proved2/0 pair. Local half-cycle
# and coherent bridge-to-SYS publication remain ordinary fully timed paths.
set_multicycle_path -setup -end 2 -from $sar_sdram_dq -to $sar_sdram_capture
set_multicycle_path -hold -end 0 -from $sar_sdram_dq -to $sar_sdram_capture
derive_clock_uncertainty
