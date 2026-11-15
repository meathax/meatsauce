# Selected output aliases only. All concurrent root clocks remain related
# by ordinary STA, including live packets, held mode controls and raw resets.
set sel_hdmi_mux [get_pins -compatibility_mode {*hdmi_handoff|clk_mux|outclk}]
set sel_vga_mux [get_pins -compatibility_mode {vga_clk_sw|outclk}]
if {[get_collection_size $sel_hdmi_mux]!=1 || [get_collection_size $sel_vga_mux]!=1} {error "Selected output mux identity changed"}
foreach mux [list $sel_hdmi_mux $sel_vga_mux] label {hdmi vga} {
 create_generated_clock -name seicro_${label}_selected_native -source $sio_native_source -master_clock $sio_native -divide_by 1 $mux
 create_generated_clock -name seicro_${label}_selected_scaler -source $sio_scaler_source -master_clock $sio_scaler -divide_by 1 -add $mux
}
# Forwarded inverted DDIO output is downstream of the selected mux clock.
# This preserves actual source/network latency; no period/phase relaxation.
create_generated_clock -name seicro_hdmi_native -source $sel_hdmi_mux -master_clock [get_clocks seicro_hdmi_selected_native] -divide_by 1 -invert $sio_pad
create_generated_clock -name seicro_hdmi_scaler -source $sel_hdmi_mux -master_clock [get_clocks seicro_hdmi_selected_scaler] -divide_by 1 -invert -add $sio_pad
foreach clock {seicro_hdmi_scaler seicro_hdmi_native} {
    # ADV7513 RevB table1: setup1.8/hold1.3ns plus assumed +/-0.5ns board skew.
    set_output_delay -clock $clock -max 2.3 -add_delay $sio_video
    set_output_delay -clock $clock -min -1.8 -add_delay $sio_video
}
derive_clock_uncertainty
proc selected_data_pins {pattern bank} {
 set pins [get_pins -compatibility_mode $pattern]
 set canonical {}
 foreach_in_collection p $pins {
  set n [get_pin_info -name $p]
  regsub {~DUPLICATE(_[0-9]+)?\|} $n {|} n
  regsub {~_Duplicate_[0-9]+\|} $n {|} n
  if {![regexp {^hdmi_handoff\|(native_cap|stage)\[([0-9]+)\]\|(d|asdata)$} $n all role bit kind] || $role ne $bank || $bit>26} {error "Unreviewed selected data pin $n"}
  lappend canonical $n
 }
 for {set bit 0} {$bit<27} {incr bit} {
  set found 0
  foreach kind {d asdata} {
   set required [format {hdmi_handoff|%s[%d]|%s} $bank $bit $kind]
   if {[lsearch -exact $canonical $required]>=0} {set found 1}
  }
  if {!$found} {error "Missing selected data pin $bank $bit"}
 }
 return $pins
}
set sel_native_d [selected_data_pins {*hdmi_handoff|native_cap*|d *hdmi_handoff|native_cap*|asdata} native_cap]
set sel_stage_d [selected_data_pins {*hdmi_handoff|stage*|d *hdmi_handoff|stage*|asdata} stage]
foreach label {hdmi vga} {
 set_clock_groups -exclusive -group [get_clocks seicro_${label}_selected_native] -group [get_clocks seicro_${label}_selected_scaler]
}
set_false_path -from $sio_native -through $sel_native_d -to [get_clocks seicro_hdmi_selected_scaler]
set_false_path -from $sio_scaler -through $sel_stage_d -to [get_clocks seicro_hdmi_selected_native]
set_false_path -from [get_clocks seicro_hdmi_selected_native] -to [get_clocks seicro_hdmi_scaler]
set_false_path -from [get_clocks seicro_hdmi_selected_scaler] -to [get_clocks seicro_hdmi_native]
