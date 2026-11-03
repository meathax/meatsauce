# Selected-clock ownership from the actual one-output HDMI mux.
# See docs/TIMING_REPAIRS_20261023.md and the all-eight-condition mux probe.
# Parent roots remain timed for the real held-data CDC transfers.
set mm_mux_core [get_clocks {*platform_pll*PLL_OUTPUT_COUNTER*divclk}]
set mm_mux_hdmi [get_clocks {pll_hdmi|*|divclk}]
set mm_mux_output [get_pins -compatibility_mode {hdmi_clk_sw|outclk}]
set mm_mux_core_input [get_pins -compatibility_mode {hdmi_clk_sw|inclk[3]}]
set mm_mux_hdmi_input [get_pins -compatibility_mode {hdmi_clk_sw|inclk[2]}]
foreach collection [list $mm_mux_core $mm_mux_hdmi $mm_mux_output $mm_mux_core_input $mm_mux_hdmi_input] {
 if {[get_collection_size $collection]!=1} {error "Exact HDMI mux topology required"}
}
foreach_in_collection c $mm_mux_core {set mm_mux_core_name [get_clock_info -name $c]}
foreach_in_collection c $mm_mux_hdmi {set mm_mux_hdmi_name [get_clock_info -name $c]}
create_generated_clock -name madmotor_hdmi_direct -source $mm_mux_core_input -master_clock $mm_mux_core_name -divide_by 1 $mm_mux_output
create_generated_clock -name madmotor_hdmi_scaled -source $mm_mux_hdmi_input -master_clock $mm_mux_hdmi_name -divide_by 1 -add $mm_mux_output
set mm_mux_direct [get_clocks madmotor_hdmi_direct]
set mm_mux_scaled [get_clocks madmotor_hdmi_scaled]
if {[get_collection_size $mm_mux_direct]!=1 || [get_collection_size $mm_mux_scaled]!=1} {error "Selected clocks missing"}
set_clock_groups -logically_exclusive -group $mm_mux_direct -group $mm_mux_scaled
set mm_mux_dv_regs [get_registers {hdmi_dv_data[*] hdmi_dv_hs hdmi_dv_vs hdmi_dv_de}]
set mm_mux_selected_regs [get_registers {d[*] hs vs de}]
if {[get_collection_size $mm_mux_dv_regs]!=27 || [get_collection_size $mm_mux_selected_regs]!=27} {error "Expected exact27+27 data-branch registers"}
# In scaled mode this capture is not consumed. In direct mode the scaler
# inputs to the second stage are not selected. No parent-to-parent CDC cut.


proc mm_mux_capture_pins {registers patterns} {
 set pins [get_pins -compatibility_mode $patterns]
 set names [list]
 set allowed [dict create]
 set covered [dict create]
 foreach_in_collection r $registers {dict set allowed [get_register_info -name $r] 1}
 foreach_in_collection pin $pins {
  set name [get_node_info -name $pin]
  if {[regexp {^(.*)\|(d|asdata|sload)$} $name all reg port]} {
   if {![dict exists $allowed $reg]} {error "Foreign capture pin $name"}
   dict set covered $reg 1
   lappend names $name
  }
 }
 set capture [get_pins -compatibility_mode $names]
 if {[dict size $covered]!=27 || [get_collection_size $capture]<27 || [get_collection_size $capture]>81} {error "Incomplete27-register capture pin coverage"}
 return $capture
}
set mm_mux_dv_pins [mm_mux_capture_pins $mm_mux_dv_regs {hdmi_dv_data[*]|* hdmi_dv_hs|* hdmi_dv_vs|* hdmi_dv_de|*}]
set mm_mux_selected_pins [mm_mux_capture_pins $mm_mux_selected_regs {d[*]|* hs|* vs|* de|*}]
set_false_path -from $mm_mux_core -to $mm_mux_scaled -through $mm_mux_dv_pins
set_false_path -from $mm_mux_hdmi -to $mm_mux_direct -through $mm_mux_selected_pins
