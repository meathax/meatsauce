# Standard 3.3V MiSTer SDR SDRAM envelope, CL2/BL2 at 56 MHz.
# tAC<=8ns, tOH>=2ns, tIS<=2ns, tIH<=1ns;
# independent clock/data PCB flight each 0..2ns. FPGA pad/clock insertion
# is fitted by TimeQuest, not included again in these board delays.
# Reference and edge proof: docs/SDRAM_TIMING.md.
# Physical source is inverted c0 even while c1 is active for DQ capture.
# Do not infer the clock driver from which PLL outputs survive synthesis.
set forwarded_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $forwarded_source]!=1} {error "expected exact forwarded c0 source"}
create_generated_clock -name SDRAM_CLK -source $forwarded_source -divide_by 1 -phase 180 [get_ports SDRAM_CLK]
set memory_clock [get_clocks {SDRAM_CLK}]
if {[get_collection_size $memory_clock] != 1} { error "SDRAM_CLK must precede SDRAM I/O constraints" }
set capture_clock [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $capture_clock]!=1} {error "expected related 56MHz +2232ps capture clock"}
set dq_ports [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $dq_ports] != 16} { error "expected 16 SDRAM DQ pins" }
set captures [get_registers {*|jtframe_sdram64:u_sdram|dq_capture[*]}]
if {[get_collection_size $captures] != 16} { error "expected 16 falling-edge SDRAM input registers" }
set_input_delay -clock $memory_clock -max 12.0 $dq_ports
set_input_delay -clock $memory_clock -min 2.0 $dq_ports
# Capture previous launched beat, not the replacement after the current S edge.
# Proven logical setup20.089ns and hold2.232ns; see SDRAM_EDGE_PROOF.md.
# Hold0 deliberately retains the strict current-cycle replacement check.
set_multicycle_path -setup 2 -end -from $dq_ports -to $captures
set_multicycle_path -hold 0 -end -from $dq_ports -to $captures
set outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE}]
if {[get_collection_size $outputs] != 38} { error "expected 38 SDRAM data/control output pins" }
set_output_delay -clock $memory_clock -max 4.0 $outputs
set_output_delay -clock $memory_clock -min -3.0 $outputs
derive_clock_uncertainty
