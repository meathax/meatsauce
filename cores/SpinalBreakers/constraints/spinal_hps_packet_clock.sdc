# SPINAL HPS observer held packet only. No SDRAM, clock-group or false-path edit.
# Native all-eight proof: evidence/quartus-hps-clock-probe-20261101-01/.
# Source HPS100 -> destination clk_sys=630/11MHz; existing coherent held packet.
proc spinal_apply_hps_packet_clock_contract {} {
 set hps [get_clocks {*|h2f_user0_clk}]
 set sys [get_clocks {*emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
 set held [get_registers {*|metrics_transfer|held_payload[*]}]
 set dest [get_registers {*|metrics_transfer|dst_data[*]}]
 set pins [get_pins -compatibility_mode {*|metrics_transfer|held_payload[*]|clk}]
 if {[get_collection_size $hps]!=1 || [get_collection_size $sys]!=1 || [get_collection_size $held]!=128 || [get_collection_size $dest]!=128 || [get_collection_size $pins]!=128} {error "SPINAL HPS packet clock/endpoint inventory changed"}
 set master [get_clock_info -name $hps]
 set root [get_pins -compatibility_mode $master]
 if {[get_collection_size $root]!=1 || abs([get_clock_info -period $hps]-10.000)>.0001 || abs([get_clock_info -period $sys]-17.460)>.0001} {error "SPINAL HPS packet physical clock profile changed"}
 # A divide-by-one description of the actual HPS clock at these physical leaves.
 # It retains master waveform and fitted insertion, and targets no other sinks.
 create_generated_clock -name spinal_metrics_hps_physical -master_clock $master -source $root -divide_by 1 $pins
 set_max_delay -from $held -to $dest 17.460
 set_min_delay -from $held -to $dest -10.000
 derive_clock_uncertainty
}
spinal_apply_hps_packet_clock_contract
rename spinal_apply_hps_packet_clock_contract {}
