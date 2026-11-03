# AS4C16M16SA-6TCN/-6TIN CL2/BL2 target profile, official C&I Rev3.0 p19.
# tACmax6.0ns, tOHmin2.5ns, tIS1.5ns, tIH0.8ns, tCKmin10ns at CL2.
# Qualification envelope (not measured user hardware): each clock/data PCB
# flight0..1ns, clock-to-output-board skew<=0.5ns. No copied FPGA insertion.
# Forwarded72MHz PLL output1 phase-4513ps is unchanged; model the actual pad.
set snk68_mem_master {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set snk68_mem_source [get_pins -compatibility_mode $snk68_mem_master]
if {[get_collection_size $snk68_mem_source]!=1} {error "SNK68 forwarded SDRAM source inventory"}
create_generated_clock -name snk68_sdram_clk -source $snk68_mem_source -master_clock $snk68_mem_master -divide_by 1 [get_ports SDRAM_CLK]
set snk68_dq [get_ports {SDRAM_DQ[*]}]
set snk68_mem_output [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $snk68_dq]!=16 || [get_collection_size $snk68_mem_output]!=38} {error "SNK68 memory pad inventory"}
# Input arrival includes clock outbound+data return flight exactly once.
set_input_delay -clock snk68_sdram_clk -max 8.0 $snk68_dq
set_input_delay -clock snk68_sdram_clk -min 2.5 -add_delay $snk68_dq
# Output requirement includes external setup/hold plus bounded relative skew.
set_output_delay -clock snk68_sdram_clk -max 2.0 $snk68_mem_output
set_output_delay -clock snk68_sdram_clk -min -1.3 -add_delay $snk68_mem_output
set snk68_mem_capture [get_registers {*|sdram|sampled_data[*]}]
if {[get_collection_size $snk68_mem_capture]!=16} {error "SNK68 expects16 rising-edge input captures"}
# Target edge/word proof: rising SYS capture physically precedes the current
# forwarded-pad edge because its native clock insertion is later. The captured
# CL2 word belongs to the preceding external launch, not the next beat.
# Setup2 indexes that preceding word; hold0 retains the NEXT external-word
# boundary. This is not a two-cycle data-stability or divided-capture claim.
# Native expected normalized edges (72MHz/-4513ps): setup9.375->27.776,
# hold9.375->13.888. Verify actual edges, all16 lanes and all4models after FIT.
# The source first-word/read-complete counters include the input-stage cycle.
# Route-aware320read/192write proof and early/late/falling negatives are retained.
set_multicycle_path -setup -end 2 -from $snk68_dq -to $snk68_mem_capture
set_multicycle_path -hold -end 0 -from $snk68_dq -to $snk68_mem_capture
derive_clock_uncertainty
