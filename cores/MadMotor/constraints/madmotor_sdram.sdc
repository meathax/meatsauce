# Standard32MB primary SDRAM target, Winbond W9825G6KH-6 CL2 reference.
# Clock/data flight each0..1ns; tAC6ns, conservative tOH2.5ns, tSU1.5/tH0.8ns.
# Reference physical output pin; count each board flight once.
set mm_sdram_core [get_clocks {*platform_pll*PLL_OUTPUT_COUNTER*divclk}]
if {[get_collection_size $mm_sdram_core] != 1 || abs([get_clock_info -period $mm_sdram_core]-1000.0/60)>0.001} {error "SDRAM core clock/profile changed"}
set mm_sdram_source [get_clock_info -targets $mm_sdram_core]
set mm_sdram_clkport [get_ports {SDRAM_CLK}]
set mm_sdram_dq [get_ports {SDRAM_DQ[*]}]
set mm_sdram_outputs [remove_from_collection [get_ports {SDRAM_*}] $mm_sdram_clkport]
if {[get_collection_size $mm_sdram_source] != 1 || [get_collection_size $mm_sdram_clkport] != 1 || [get_collection_size $mm_sdram_dq] != 16 || [get_collection_size $mm_sdram_outputs] != 38} {error "SDRAM clock/pin inventory changed"}
create_generated_clock -name madmotor_sdram_forwarded -source $mm_sdram_source -master_clock $mm_sdram_core -divide_by 1 -invert $mm_sdram_clkport
set_input_delay -clock madmotor_sdram_forwarded -max 8.0 $mm_sdram_dq
set_input_delay -clock madmotor_sdram_forwarded -min 2.5 $mm_sdram_dq
set_output_delay -clock madmotor_sdram_forwarded -max 2.5 $mm_sdram_outputs
set_output_delay -clock madmotor_sdram_forwarded -min -1.8 $mm_sdram_outputs
derive_clock_uncertainty
# No false path, multicycle or period/phase relaxation. The private controller
# captures on the falling root edge and consumers remain on the rising edge.
