# Both PLL outputs are related. No clock groups or CPU multicycle applies.
# Q17 max/min delay includes clock latency (no -datapath_only support).
# Post-route audit must independently inspect actual bundle data delay.
proc f3_required {pattern} {
 set nodes [get_registers $pattern]
 if {[get_collection_size $nodes]==0} {error "F3 CDC endpoint missing: $pattern"}
 return $nodes
}
proc f3_first_stage {pattern} {
 set nodes [f3_required $pattern]
 set count 0
 foreach_in_collection node $nodes {
  set name [get_register_info -name $node]
  # req_s* also matches req_sync: never cut that second synchronizer stage.
  if {[string match {*|req_sync*} $name]} {continue}
  set entry [f3_required [list $name]]
  set destinations [get_fanouts $entry]
  if {[get_collection_size $destinations]!=1} {error "F3 CDC entry has functional/multiple fanout: $name"}
  set_false_path -to $entry
  foreach_in_collection destination $destinations {
   post_message -type info "F3 CDC entry topology: $name -> [get_node_info -name $destination]"
  }
  incr count
 }
 if {$count==0} {error "F3 CDC entry stage missing: $pattern"}
 post_message -type info "F3 CDC first stage: $pattern ($count)"
}
proc f3_bundle {source target limit} {
 set launches [f3_required $source]
 if {$target eq "FANOUT"} {set captures [get_fanouts $launches]} else {set captures [f3_required $target]}
 if {[get_collection_size $captures]==0} {error "F3 CDC capture missing: $source"}
 set_max_delay $limit -from $launches -to $captures
 set_min_delay 0.0 -from $launches -to $captures
 post_message -type info "F3 CDC bundle: $source -> $target max=$limit ([get_collection_size $launches]/[get_collection_size $captures])"
}
# First-stage cuts only: every functional consumer is beyond another timed
# synchronizer stage. Channel 3/4/7/8 requests already originate in RAM domain.
foreach p {
 {*sdram:sdram|ch1_req_s} {*sdram:sdram|ch2_req_s} {*sdram:sdram|ch5_req_s} {*sdram:sdram|ch6_req_s}
 {*rf_sdram_ch3_arb:main_channel|req_s*}
 {*rf_spr_ch_share:spr_ch_share_a|req_s*} {*rf_spr_ch_share:spr_ch_share_b|req_s*}
 {*rf_prog_bus:prog_bus|done_s} {*rf_prog_bus:prog|done_s}
 {*rf_workram:main_workram|done_s} {*rf_smp_bus:smp_bus|d_s}
 {*rf_gfx_bus:gfx|lo_s} {*rf_gfx_bus:gfx|hi_s}
 {*rf_spr_gfx_bus:gfx_a|lo_s} {*rf_spr_gfx_bus:gfx_a|hi_s}
 {*rf_spr_gfx_bus:gfx_b|lo_s} {*rf_spr_gfx_bus:gfx_b|hi_s}
 {*emu|ld_d1}
 {*rf_pivot_bus:u_pivot_bus|wr_ack_s} {*rf_pivot_bus:u_pivot_bus|complete_s}
 {*rf_pivot_bus:u_pivot_bus|wr_s} {*rf_pivot_bus:u_pivot_bus|request_s} {*rf_pivot_bus:u_pivot_bus|reset_s}
} {f3_first_stage $p}
# Forward payload: held until ACK, including across soft reset; consumption
# occurs no earlier than two RAM periods (~20.61 ns). Budget 12 ns.
foreach p {{*rf_gfx_bus:gfx|ch_lo_addr*} {*rf_gfx_bus:gfx|ch_hi_addr*}
 {*rf_prog_bus:prog|ch_addr*} {*rf_smp_bus:smp_bus|ch_addr*}} {
 f3_bundle $p {*sdram:sdram|*} 12.0
}
foreach p {{*rf_prog_bus:prog_bus|ch_addr*} {*rf_prog_bus:prog_bus|ch_rnw*} {*rf_workram:main_workram|ch_addr*}
 {*rf_workram:main_workram|ch_din*} {*rf_workram:main_workram|ch_be*}
 {*rf_workram:main_workram|ch_rnw*} {*emu|ld_addr*} {*emu|ld_din*}} {
 f3_bundle $p {*rf_sdram_ch3_arb:main_channel|*} 12.0
}
foreach p {{*rf_spr_gfx_bus:gfx_a|ch_lo_addr*} {*rf_spr_gfx_bus:gfx_a|ch_hi_addr*}} {
 f3_bundle $p {*rf_spr_ch_share:spr_ch_share_a|ch_addr*} 12.0
}
foreach p {{*rf_spr_gfx_bus:gfx_b|ch_lo_addr*} {*rf_spr_gfx_bus:gfx_b|ch_hi_addr*}} {
 f3_bundle $p {*rf_spr_ch_share:spr_ch_share_b|ch_addr*} 12.0
}
foreach p {{*rf_pivot_bus:u_pivot_bus|wr_addr*} {*rf_pivot_bus:u_pivot_bus|wr_data*}
 {*rf_pivot_bus:u_pivot_bus|wr_mask*} {*rf_pivot_bus:u_pivot_bus|request_row*}
 {*rf_pivot_bus:u_pivot_bus|request_bank*}} {
 f3_bundle $p {*rf_pivot_bus:u_pivot_bus|ch_* *rf_pivot_bus:u_pivot_bus|fill_*} 12.0
}
# Return bundles: toggle pipeline delays use by >=3 SYS periods (~56.21 ns).
# Data persists until a subsequent completion; reset drains before re-use.
foreach p {{*rf_prog_bus:prog_bus|ram_dout*} {*rf_prog_bus:prog|ram_dout*}
 {*rf_workram:main_workram|ram_reply*} {*rf_smp_bus:smp_bus|ram_line*}
 {*rf_gfx_bus:gfx|lo_ram*} {*rf_gfx_bus:gfx|hi_ram*}
 {*rf_spr_gfx_bus:gfx_a|lo_ram*} {*rf_spr_gfx_bus:gfx_a|hi_ram*}
 {*rf_spr_gfx_bus:gfx_b|lo_ram*} {*rf_spr_gfx_bus:gfx_b|hi_ram*}} {
 f3_bundle $p FANOUT 30.0
}
