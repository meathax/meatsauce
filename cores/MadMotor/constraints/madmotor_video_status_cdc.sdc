# Only asynchronous first samples. Related direct-video->core transfers and
# every subsequent synchronizer stage remain full-rate timed.
set mm_status_core_first [get_registers {*hdmi_vs_core_sync[0]}]
set mm_status_measure_first [get_registers {*hdmi_vs_measure_sync[0]}]
set mm_status_vs_source [get_registers {*hdmi_out_vs*}]
if {[get_collection_size $mm_status_core_first]!=1 || [get_collection_size $mm_status_measure_first]!=1} {error "Video status first-stage inventory changed"}
if {[get_collection_size $mm_status_vs_source]<1 || [get_collection_size $mm_status_vs_source]>4} {error "Video status source inventory changed"}
if {[get_collection_size $mm_mux_scaled]!=1} {error "Scaled HDMI clock missing"}
set_false_path -from $mm_mux_scaled -to $mm_status_core_first
set_false_path -from $mm_status_vs_source -to $mm_status_measure_first

# Polyphase adaptive flags are written by the host's poly_clk==clk_sys.
# The two axis enables are independent level controls; coefficient RAM retains
# its original dual-clock protocol. Never cut the second-stage/use paths.
set mm_status_poly_sources [get_registers {*ascal|o_v_poly_adaptive *ascal|o_h_poly_adaptive}]
set mm_status_poly_first [get_registers {*ascal|o_poly_adaptive_meta[*]}]
set mm_status_poly_second [get_registers {*ascal|o_poly_adaptive_sync[*]}]
# Require both logical axis controls and every bounded fitted source copy.
# A physical duplicate can retain same-clock feedback without adding a new
# asynchronous consumer. Only the two existing first-stage endpoints are cut.
proc mm_status_poly_source_names {names} {
    set counts [dict create o_h_poly_adaptive 0 o_v_poly_adaptive 0]
    set seen [dict create]
    foreach name $names {
        if {![regexp {[|](o_[hv]_poly_adaptive)(~DUPLICATE[0-9]*)?$} $name match stem replica]} {error "Unexpected adaptive source: $name"}
        if {[dict exists $seen $name]} {error "Repeated adaptive source: $name"}
        dict set seen $name 1
        dict incr counts $stem
        if {[dict get $counts $stem]>4} {error "Unbounded adaptive source replicas: $stem"}
    }
    foreach stem {o_h_poly_adaptive o_v_poly_adaptive} {
        if {[dict get $counts $stem]<1} {error "Missing logical adaptive source: $stem"}
    }
    return [dict size $seen]
}
set mm_status_poly_names {}
foreach_in_collection reg $mm_status_poly_sources {lappend mm_status_poly_names [get_register_info -name $reg]}
mm_status_poly_source_names $mm_status_poly_names
if {[get_collection_size $mm_status_poly_first]!=2 || [get_collection_size $mm_status_poly_second]!=2} {error "Adaptive status stage inventory changed"}
set_false_path -from $mm_status_poly_sources -to $mm_status_poly_first

# Independent board reference oscillator consumes the low-latency enable.
# The source is a single level; keep the second stage and every use timed.
set mm_status_lowlat_source [get_registers {lowlat}]
set mm_status_lowlat_first [get_registers {*lowlat_hdmi_sync[0]}]
set mm_status_lowlat_second [get_registers {*lowlat_hdmi_sync[1]}]
if {[get_collection_size $mm_status_lowlat_source]!=1 || [get_collection_size $mm_status_lowlat_first]!=1 || [get_collection_size $mm_status_lowlat_second]!=1} {error "Low-latency status inventory changed"}
set_false_path -from $mm_status_lowlat_source -to $mm_status_lowlat_first
