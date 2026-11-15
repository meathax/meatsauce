# Supported SDRAM envelope, not an identification of the user's module:
# tAC<=6ns, tOH>=2.5ns, input setup<=1.8ns, input hold<=1ns;
# one-way clock and data flight each0..1ns. These include flight exactly once.
# Source: retained Micron MT48LC16M16A2 model (5.4/3.0/1.5/0.8ns),
# conservative portable envelope from Seicross lessons16185/17094.
# Clock is the physical SDRAM clock pad; never cut the related capture domain.
set dq [get_ports {SDRAM_DQ[*]}]
set outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_CKE SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQ[*]}]
set memory_clock [get_clocks SDRAM_CLK]
if {[get_collection_size $dq] != 16 || [get_collection_size $outputs] != 38 || [get_collection_size $memory_clock] != 1} {
    error "Seicross physical SDRAM port/clock contract changed"
}
set_input_delay -clock $memory_clock -max 8.0 $dq
set_input_delay -clock $memory_clock -min 2.5 $dq
set_output_delay -clock $memory_clock -max 2.8 $outputs
set_output_delay -clock $memory_clock -min -2.0 $outputs
