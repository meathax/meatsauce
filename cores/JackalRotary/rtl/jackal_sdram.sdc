# Micron MT48LC16M16A2 Rev D Table12 and CAS-latency description:
# https://www.micron-electronic.com/pdf-86/mt48lc16m16a2p-6a-aat-g-tr.pdf
# CL2/BL1 profile covers tAC<=7.5ns, tOHn>=1.8ns, tIS1.5/tIH0.8ns.
# Assume <=1ns each outbound-clock/data-return flight (2ns round trip),
# zero minimum flight and <=0.5ns output clock/data skew. Not board measurements.
# The actual DDIO drives h=0,l=1: the forwarded clock is inverted.
set jackal_sdram_master {}
foreach_in_collection c [get_clocks *] {
    set n [get_clock_info -name $c]
    if {[string first {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk} $n] == 0} {
        set jackal_sdram_master $n
    }
}
if {$jackal_sdram_master eq {}} {error {Missing Jackal SDRAM master clock}}
set jackal_sdram_source [get_pins -compatibility_mode $jackal_sdram_master]
if {[get_collection_size $jackal_sdram_source] != 1} {error {SDRAM clock source must resolve once}}
create_generated_clock -name jackal_sdram_clk -source $jackal_sdram_source \
    -master_clock $jackal_sdram_master -divide_by 1 -invert [get_ports SDRAM_CLK]
set jackal_sdram_dq [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $jackal_sdram_dq] != 16} {error {SDRAM DQ must resolve 16 ports}}
set jackal_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $jackal_sdram_outputs] != 38} {error {SDRAM outputs must resolve 38 ports including constants}}
set_output_delay -clock jackal_sdram_clk -max 2.0 $jackal_sdram_outputs
set_output_delay -clock jackal_sdram_clk -min -1.3 -add_delay $jackal_sdram_outputs
set_input_delay -clock jackal_sdram_clk -max 9.5 $jackal_sdram_dq
set_input_delay -clock jackal_sdram_clk -min 1.8 -add_delay $jackal_sdram_dq
set jackal_sdram_capture [get_registers {*|sdram|sampled_data[*]}]
if {[get_collection_size $jackal_sdram_capture] != 16} {error {SDRAM capture must resolve 16 endpoints}}
# No multicycle: external DQ launch and negative-edge capture are a full
# period apart; the local negative-to-positive publication is a half period.
# A slower transaction rate alone would not justify relaxing either path.
derive_clock_uncertainty
