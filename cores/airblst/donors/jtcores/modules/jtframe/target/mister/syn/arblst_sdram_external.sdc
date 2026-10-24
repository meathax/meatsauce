# Explicit Alliance AS4C32M16SB/AS4C16M16SA -6/-7 CL2 model; profile in manifest.json.
# Reference is the existing forwarded physical SDRAM_CLK pad clock.
# No multicycle, clock cut, phase change, or inferred board measurement.
if {[get_collection_size [get_clocks SDRAM_CLK]] != 1} {error "required SDRAM_CLK missing/ambiguous"}
set ab_dq [get_ports {SDRAM_DQ[*]}]
set ab_ca [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
if {[get_collection_size $ab_dq] != 16} {error "expected sixteen DQ ports"}
if {[get_collection_size $ab_ca] != 22} {error "expected twenty-two command/address/mask/CKE ports"}
set_input_delay -clock SDRAM_CLK -max 8.000000000 $ab_dq
set_output_delay -clock SDRAM_CLK -max 2.500000000 $ab_dq
set_output_delay -clock SDRAM_CLK -max 2.500000000 $ab_ca
set_input_delay -clock SDRAM_CLK -min 0.000000000 $ab_dq
set_output_delay -clock SDRAM_CLK -min -1.800000000 $ab_dq
set_output_delay -clock SDRAM_CLK -min -1.800000000 $ab_ca
