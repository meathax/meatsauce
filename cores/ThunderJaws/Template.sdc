derive_pll_clocks

# core specific constraints

# Physical SDRAM pin envelope, not a measurement of the user's module/PCB.
# DDIO datain_h=0/datain_l=1 inverts the -90 degree PLL source: external rises at fabric+90 degrees.
# READ is registered at0T, accepted at.25T; CL2 beat0 launches at1.25T
# and is captured at 2T. Consecutive beat/command captures remain fully timed.
# Model: MT48LC16M16A2-class tACmax7.5ns/tOHmin2.5ns, tIS1.5ns/tIH0.8ns;
# outbound clock/data flight1ns each, return DQ flight1ns, counted once.
# No multicycle or false-path exception is applied to these transfers.
set tj_pll_all [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|*PLL_OUTPUT_COUNTER*|divclk}]
set tj_pll_sys [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set tj_pll_source [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $tj_pll_all] != 2 || [get_collection_size $tj_pll_sys] != 1 || [get_collection_size $tj_pll_source] != 1} {error "Expected exact native phase0 and phase-90 PLL outputs"}
if {[get_collection_size $tj_pll_source] != 1} {
    error "ThunderJaws SDRAM requires exactly one resolved core PLL output pin"
}
set tj_sdram_clock [get_ports {SDRAM_CLK}]
set tj_sdram_dq [get_ports {SDRAM_DQ[*]}]
set tj_sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE}]
if {[get_collection_size $tj_sdram_clock] != 1 || [get_collection_size $tj_sdram_dq] != 16 || [get_collection_size $tj_sdram_out] != 38} {
    error "ThunderJaws physical SDRAM port cardinality mismatch"
}
create_generated_clock -name sdram_forward -source $tj_pll_source -divide_by 1 -invert $tj_sdram_clock
set_input_delay -clock sdram_forward -max 9.5 $tj_sdram_dq
set_input_delay -clock sdram_forward -min 4.5 $tj_sdram_dq
set_output_delay -clock sdram_forward -max 1.5 $tj_sdram_out
set_output_delay -clock sdram_forward -min -0.8 $tj_sdram_out

derive_clock_uncertainty
