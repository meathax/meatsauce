# Held read descriptor, not an ordinary same-edge transfer. See
# docs/SCALER_READ_TIMING_20261024.md. No clock group or multicycle cut.
set mm_read_hdmi_clock [get_clocks {*pll_hdmi*counter[0].output_counter|divclk}]
set mm_read_avl_clock [get_clocks {*|h2f_user0_clk}]
if {[get_collection_size $mm_read_hdmi_clock]!=1 || [get_collection_size $mm_read_avl_clock]!=1} {error "Read mailbox clock inventory changed"}
if {[get_clock_info -period $mm_read_hdmi_clock]<6.730 || abs([get_clock_info -period $mm_read_avl_clock]-10.0)>0.001} {error "Read mailbox edge proof clock range exceeded"}
set mm_scaler_read_held [get_registers {*ascal|o_read_addr_hold*}]
set mm_scaler_read_dst [get_registers {*ascal|avl_read_addr_latched* *ascal|avl_address*}]
set bits [dict create]
foreach_in_collection n $mm_scaler_read_held {
    set name [get_register_info -name $n]
    if {![regexp {\|o_read_addr_hold\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name m bit copy] || $bit<4 || $bit>31} {error "Foreign held read address: $name"}
    dict incr bits $bit
    if {[dict get $bits $bit]>4} {error "Excess held read replicas"}
}
if {[dict size $bits]!=28} {error "Held read address logical bit missing"}
set bits [dict create]
foreach_in_collection n $mm_scaler_read_dst {
    set name [get_register_info -name $n]
    if {![regexp {\|(avl_read_addr_latched|avl_address)\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name m stem bit copy]} {error "Foreign read capture: $name"}
    if {($stem eq "avl_address" && ($bit<0 || $bit>27)) || ($stem eq "avl_read_addr_latched" && ($bit<4 || $bit>31))} {error "Read capture bit out of range"}
    set key "$stem/$bit"
    dict incr bits $key
    if {[dict get $bits $key]>4} {error "Excess read capture replicas"}
}
if {[dict size $bits]!=56} {error "Read capture logical bit missing"}
set_max_delay -from $mm_scaler_read_held -to $mm_scaler_read_dst 10.000
set_min_delay -from $mm_scaler_read_held -to $mm_scaler_read_dst -6.730

# Acknowledged input-bank descriptors. Full production protocol proof02 and
# fitted source03 inventory precede this budget; see scaler transfer doc.
set mm_scaler_write_held [get_registers {*ascal|i_wadrs_bank* *ascal|i_woffset_bank* *ascal|i_write_bank_seq*}]
set seen [dict create]
foreach_in_collection n $mm_scaler_write_held {
 set name [get_register_info -name $n]
 if {[regexp {\|(i_wadrs_bank|i_woffset_bank)\[([01])\]\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name m stem bank bit copy]} {
  if {($stem eq "i_wadrs_bank" && ($bit<8 || $bit>22)) || ($stem eq "i_woffset_bank" && $bit ni {23 24 29})} {error "Unexpected write descriptor bit: $name"}
  set key "$stem/$bank/$bit"
 } elseif {[regexp {\|i_write_bank_seq\[([01])\](~DUPLICATE[0-9]*)?$} $name m bank copy]} {set key "sequence/$bank"} else {error "Foreign write descriptor: $name"}
 dict incr seen $key
 if {[dict get $seen $key]>4} {error "Excess write descriptor copies"}
}
if {[dict size $seen]!=38} {error "Write descriptor logical inventory changed"}
set mm_scaler_write_dst [get_registers {*ascal|avl_address* *ascal|avl_read_addr_latched* *ascal|avl_rad* *ascal|avl_state* *ascal|avl_write_bank*}]
set seen [dict create]
foreach_in_collection n $mm_scaler_write_dst {
 set name [get_register_info -name $n]
 if {[regexp {\|(avl_address|avl_read_addr_latched|avl_rad)\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $name m stem bit copy]} {
  if {($stem eq "avl_address" && ($bit<0 || $bit>27)) || ($stem eq "avl_read_addr_latched" && ($bit<4 || $bit>31)) || ($stem eq "avl_rad" && ($bit<0 || $bit>4))} {error "Write capture bit out of range: $name"}
  set key "$stem/$bit"
 } elseif {[regexp {\|(avl_write_bank|avl_state\.sIDLE|avl_state\.sREAD|avl_state\.sWRITE)(~DUPLICATE[0-9]*)?$} $name m stem copy]} {set key $stem} else {error "Foreign write capture: $name"}
 dict incr seen $key
 if {[dict get $seen $key]>4} {error "Excess write capture copies"}
}
if {[dict size $seen]!=65} {error "Write capture logical inventory changed"}
set_max_delay -from $mm_scaler_write_held -to $mm_scaler_write_dst 10.000
set_min_delay -from $mm_scaler_write_held -to $mm_scaler_write_dst -16.666
# Six logical control families, eight independent first-stage bits. Every
# first-stage fanout and all11 interstage/history links are checked natively.
set mm_scaler_first_names {}
set mm_scaler_second_names {}
set mm_scaler_launch_names {}
foreach {source first second} {
 {*ascal|i_write_req_toggle[0]*} {*ascal|avl_write_req_meta[0]} {*ascal|avl_write_req_sync[0]}
 {*ascal|i_write_req_toggle[1]*} {*ascal|avl_write_req_meta[1]} {*ascal|avl_write_req_sync[1]}
 {*ascal|avl_write_ack_toggle[0]*} {*ascal|i_write_ack_meta[0]} {*ascal|i_write_ack_sync[0]}
 {*ascal|avl_write_ack_toggle[1]*} {*ascal|i_write_ack_meta[1]} {*ascal|i_write_ack_sync[1]}
 {*ascal|o_read} {*ascal|avl_read_sync} {*ascal|avl_read_sync2}
 {*ascal|avl_readack} {*ascal|o_readack_sync} {*ascal|o_readack_sync2}
 {*ascal|avl_readdataack} {*ascal|o_readdataack_sync} {*ascal|o_readdataack_sync2}
 {*ascal|o_vsv[0]*} {*ascal|avl_o_vs_sync} {*ascal|avl_o_vs}
} {
 mm_cdc_toggle $source $first
 set first_nodes [mm_cdc_regs $first 1]
 set second_nodes [mm_cdc_regs $second 1]
 foreach_in_collection n $first_nodes {lappend mm_scaler_first_names [get_register_info -name $n]}
 foreach_in_collection n $second_nodes {lappend mm_scaler_second_names [get_register_info -name $n]}
 foreach_in_collection n [get_registers $source] {lappend mm_scaler_launch_names [get_register_info -name $n]}
}
set mm_scaler_control_first [get_registers $mm_scaler_first_names]
set mm_scaler_control_second [get_registers $mm_scaler_second_names]
set mm_scaler_control_launch [get_registers $mm_scaler_launch_names]
set mm_scaler_history_from [get_registers {*ascal|o_readack_sync2 *ascal|o_readdataack_sync2 *ascal|avl_o_vs}]
set mm_scaler_history_to [get_registers {*ascal|o_readack_sync3 *ascal|o_readdataack_sync3 *ascal|avl_o_vs_sync2}]
foreach nodes [list $mm_scaler_history_from $mm_scaler_history_to] {if {[get_collection_size $nodes]!=3} {error "Scaler event history inventory changed"}}
