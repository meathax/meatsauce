# Isolated IO-forward duty60 candidate: inherited inverted waveform high4ns/low6ns; source counter1.
# Candidate reference-module interface contract, not measured board flight.
# AS4C16M16SA -7 CL3: tAC=5.4, tOH=2.5, tIS=1.5, tIH=0.8 ns.
# Supported clock/data/return flight budget: independently 0..1 ns each.
# The final report must state these assumptions and the selected module/load.
set penguin_forward_source [get_pins -compatibility_mode {emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $penguin_forward_source] != 1} {
    error "Expected one mapped source pin for the IO forwarding clock"
}
create_generated_clock -name penguin_sdram -source $penguin_forward_source \
    -divide_by 1 -invert [get_ports SDRAM_CLK]
derive_clock_uncertainty
set penguin_sdram_signals [get_ports {SDRAM_A* SDRAM_BA* SDRAM_DQ* SDRAM_n* SDRAM_CKE}]
set_output_delay -clock penguin_sdram -max 2.5 $penguin_sdram_signals
set_output_delay -clock penguin_sdram -min -1.8 $penguin_sdram_signals
set_input_delay -clock penguin_sdram -max 7.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock penguin_sdram -min 2.5 [get_ports {SDRAM_DQ[*]}]

# The IO input register captures the preceding external beat. Setup2 selects
# that beat; keep the next-beat hold check intact (no hold1 relaxation).
# CL3 data launch is READ+2+tAC, valid by READ+3; verify the complete pin-level
# burst and both registered pipeline stages, not a READ+3 launch model.
namespace eval ::penguin_sdram_raw_beat {
    set raw [get_registers {*graphics_sdram*negative_sample[*]}]
    set dq [get_ports {SDRAM_DQ[*]}]
    if {[get_collection_size $raw] != 16 || [get_collection_size $dq] != 16} {
        error "SDRAM raw beat scope must contain exactly16 input registers and16 DQ pads"
    }
    set_multicycle_path 2 -setup -end -from $dq -to $raw
}
