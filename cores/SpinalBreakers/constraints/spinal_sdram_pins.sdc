# Proposed extraction of the all-eight-tested conditional SDRAM pin contract.
# No HPS clock, group modification, false path or multicycle is introduced.
# Reference W9825G6KH-6, independent clock/data flights0.5..1.5ns; actual module unknown.
proc spinal_apply_sdram_pin_contract {} {
 set sys [get_clocks {*emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
 if {[get_collection_size $sys]!=1 || abs([get_clock_info -period $sys]-17.460)>.001} {error "SPINAL SDRAM physical clock profile changed"}
 set name [get_clock_info -name $sys]
 set root [get_pins -compatibility_mode $name]
 set clkport [get_ports SDRAM_CLK]
 set dq [get_ports {SDRAM_DQ[*]}]
 set outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS}]
 if {[get_collection_size $root]!=1 || [get_collection_size $clkport]!=1 || [get_collection_size $dq]!=16 || [get_collection_size $outputs]!=36} {error "SPINAL SDRAM physical pin inventory changed"}
 create_generated_clock -name spinal_sdram_forward -source $root -divide_by 1 -invert $clkport
 set_input_delay -clock spinal_sdram_forward -max 9 $dq
 set_input_delay -clock spinal_sdram_forward -min 1 $dq
 set_output_delay -clock spinal_sdram_forward -max 2.5 $outputs
 set_output_delay -clock spinal_sdram_forward -min -1.8 $outputs
 derive_clock_uncertainty
}
spinal_apply_sdram_pin_contract
rename spinal_apply_sdram_pin_contract {}
