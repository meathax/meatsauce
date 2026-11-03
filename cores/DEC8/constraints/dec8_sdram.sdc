# DEC8 48MHz / CL3 SDR SDRAM, referenced at the physical forwarded clock pad.
# Primary spec and explicit board assumptions: docs/SDRAM_PHYSICAL_TIMING.md.
# Read after derive_pll_clocks. Actual source/polarity; no PLL phase or exception changes.
proc dec8_sdram_require_count {label objects expected} {
    set actual [get_collection_size $objects]
    if {$actual != $expected} {
        error "DEC8 SDRAM $label selected $actual objects; expected $expected"
    }
    return $objects
}

set dec8_sdram_source_name {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set dec8_sdram_source [dec8_sdram_require_count source_pin [get_pins $dec8_sdram_source_name] 1]
set dec8_sdram_master [dec8_sdram_require_count source_clock [get_clocks $dec8_sdram_source_name] 1]
set dec8_sdram_clk_port [dec8_sdram_require_count clock_port [get_ports {SDRAM_CLK}] 1]
# Existing clk_sys PLL out0 is the real forwarding source. The actual DDIO
# high0/low1 inversion is represented once; include the physical pad path.
create_generated_clock -name dec8_sdram_pad -source $dec8_sdram_source \
    -master_clock $dec8_sdram_source_name -divide_by 1 -invert $dec8_sdram_clk_port
set dec8_sdram_pad [dec8_sdram_require_count pad_clock [get_clocks {dec8_sdram_pad}] 1]

set dec8_sdram_dq [dec8_sdram_require_count dq [get_ports {SDRAM_DQ[*]}] 16]
dec8_sdram_require_count address [get_ports {SDRAM_A[*]}] 13
dec8_sdram_require_count bank [get_ports {SDRAM_BA[*]}] 2
dec8_sdram_require_count masks [get_ports {SDRAM_DQML SDRAM_DQMH}] 2
dec8_sdram_require_count commands [get_ports {SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}] 5
set dec8_sdram_write [dec8_sdram_require_count write_ports [get_ports {
    SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH
    SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE
}] 38]

# Alliance AS4C32M16SB-7, CL3: tAC(max)=5.4ns, tOH(min)=2.5ns,
# tIS(min)=1.5ns, tIH(min)=0.8ns. Board-flight envelope is an engineering
# assumption, NOT a measured board fact: each FPGA-pad <-> SDRAM-pin leg
# lies in [0,1.5]ns. Zero is the conservative earliest-arrival bound, not
# a zero-delay waiver. The full clock flight AND returning-data flight
# are included for reads; differential data/clock skew for writes.
set dec8_sdram_tac 5.4
set dec8_sdram_toh 2.5
set dec8_sdram_tis 1.5
set dec8_sdram_tih 0.8
set dec8_sdram_clock_flight_min 0.0
set dec8_sdram_clock_flight_max 1.5
set dec8_sdram_data_flight_min 0.0
set dec8_sdram_data_flight_max 1.5
set dec8_sdram_read_max [expr {$dec8_sdram_clock_flight_max+$dec8_sdram_tac+$dec8_sdram_data_flight_max}]
# Burst-end Hi-Z has no guaranteed positive minimum: retain0ns earliest input change.
set dec8_sdram_read_min [expr {$dec8_sdram_clock_flight_min+$dec8_sdram_data_flight_min}]
set dec8_sdram_write_max [expr {$dec8_sdram_tis+$dec8_sdram_data_flight_max-$dec8_sdram_clock_flight_min}]
set dec8_sdram_write_min [expr {-$dec8_sdram_tih+$dec8_sdram_data_flight_min-$dec8_sdram_clock_flight_max}]
set_input_delay -clock $dec8_sdram_pad -max $dec8_sdram_read_max $dec8_sdram_dq
set_input_delay -clock $dec8_sdram_pad -min $dec8_sdram_read_min $dec8_sdram_dq
set_output_delay -clock $dec8_sdram_pad -max $dec8_sdram_write_max $dec8_sdram_write
set_output_delay -clock $dec8_sdram_pad -min $dec8_sdram_write_min $dec8_sdram_write

# No false paths, multicycles, clock-as-data delay, or PLL phase edit.
# SDRAM_nCS and CKE are constant in this controller; selectors still cover
# their physical ports, but no register-to-pin timing paths are expected.
