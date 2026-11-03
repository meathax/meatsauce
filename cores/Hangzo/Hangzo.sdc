# sys/sys_top.sdc owns root/PLL clock derivation and framework constraints.
# The physical forwarded clock must be included in external read/write STA.
# Source is the actual mapped PLL output pin, not an eliminated DDIO wrapper
# port. Derivation happens in sys_top.sdc before this file is read.
set hangzo_pll_clocks [get_clocks {*|clock_source|*~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $hangzo_pll_clocks] != 2} {
    error "Hangzo: expected shared root and related SDRAM phase clocks"
}
set hangzo_root_count 0
set hangzo_memory_count 0
foreach_in_collection hangzo_clock $hangzo_pll_clocks {
    if {abs([get_clock_info -period $hangzo_clock]-17.857142857) > 0.001} {
        error "Hangzo: PLL clock period changed"
    }
    set hangzo_rise [lindex [get_clock_info -waveform $hangzo_clock] 0]
    if {abs($hangzo_rise) < 0.001} {
        incr hangzo_root_count
        set hangzo_root_name [get_clock_info -name $hangzo_clock]
        set hangzo_root_clock $hangzo_clock
    } elseif {abs($hangzo_rise-8.929) < 0.010} {
        incr hangzo_memory_count
        set hangzo_forward_clock $hangzo_clock
    } else {error "Hangzo: unexpected PLL phase $hangzo_rise"}
}
if {$hangzo_root_count != 1 || $hangzo_memory_count != 1} {
    error "Hangzo: missing unique shared root or 8929ps SDRAM phase"
}
# The framework's stock PLL group selector expects a pll_inst level, while
# this core's mapped root is emu|core|clock_source|pll|altera_pll_i|... .
# sys_top's hdmi_clk_sw selects this root for direct video or the HDMI PLL
# for scaled output; its matching data mux keeps the inactive mode branch
# from feeding the registered output. Fail closed on both exact mux sources.
set hangzo_hdmi_mode_name {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set hangzo_hdmi_mode_count 0
foreach_in_collection hangzo_candidate_clock [get_clocks *] {
    if {[get_clock_info -name $hangzo_candidate_clock] eq $hangzo_hdmi_mode_name} {
        incr hangzo_hdmi_mode_count
    }
}
# Convert the enumerated exact names into clock collections. Quartus 17
# rejects the opaque clk_N iterator IDs when passed directly to set_clock_groups.
set hangzo_root_clock [get_clocks $hangzo_root_name]
set hangzo_hdmi_mode_clock [get_clocks $hangzo_hdmi_mode_name]
if {$hangzo_root_count != 1 || $hangzo_hdmi_mode_count != 1 ||
    [get_collection_size $hangzo_root_clock] != 1 ||
    [get_collection_size $hangzo_hdmi_mode_clock] != 1} {
    error "Hangzo: expected unique direct-video and HDMI-mode clock sources"
}
# Both parent clocks remain live for configuration/metadata CDC. The exact
# selected-clock output data pins receive mode exceptions below.

set hangzo_forward_source [get_clock_info -targets $hangzo_forward_clock]
if {[get_collection_size $hangzo_forward_source] != 1} {
    error "Hangzo: expected exactly one SDRAM forwarding clock source"
}
create_generated_clock -name hangzo_sdram_pad -source $hangzo_forward_source -divide_by 1 [get_ports SDRAM_CLK]

# Supported electrical envelope: AS4C16M16SA -6/-7-compatible 3.3V modules,
# CL2 tAC<=6ns, tOH>=2.5ns, tIS<=1.5ns, tIH<=0.8ns. Each clock/data path
# from the FPGA pin to/from the part is bounded by [0,2]ns. These are support
# requirements, not measured flight times or a claim for arbitrary modules.
# Input max = CLKflight_max+tAC+DQflight_max; min uses minimum flights+tOH.
# Output max = tIS+DATAflight_max-CLKflight_min; min=-tIH+DATAmin-CLKmax.
set hangzo_sdram_data [get_ports {SDRAM_DQ[*]}]
set hangzo_sdram_command [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE}]
if {[get_collection_size $hangzo_sdram_data] != 16 || [get_collection_size $hangzo_sdram_command] != 22} {
    error "Hangzo: required SDRAM pin collections changed"
}

proc hangzo_logical_register_count {register_collection} {
    set logical_names [dict create]
    set physical_names [list]
    foreach_in_collection register $register_collection {
        set register_name [get_object_info -name $register]
        lappend physical_names $register_name
        regsub {~(_Duplicate_[0-9]+|DUPLICATE)$} $register_name "" base_name
        dict set logical_names $base_name 1
    }
    foreach base_name [dict keys $logical_names] {
        if {[lsearch -exact $physical_names $base_name] < 0} {error "Hangzo: fitted replica lacks its original $base_name"}
    }
    return [dict size $logical_names]
}

# Fixed hard-interface clock associations; never cut real FPGA-facing paths.
# Native scope proof: 2384 required paths preserved, broad-cut negative rejected.
set ::hangzo_root_name $hangzo_root_name
set ::hangzo_hdmi_mode_name $hangzo_hdmi_mode_name
source [file join [file dirname [info script]] constraints hangzo_hps_affinity.tcl]
source [file join [file dirname [info script]] constraints hangzo_mode_scope.tcl]

# One asynchronous vertical-sync level is sampled in the audio/palette clock
# domain by the existing two-stage synchronizer; cut only its first stage.
set hangzo_hdmi_vs_source [get_registers {ascal:ascal|o_vs}]
set hangzo_palette_vs_sync1 [get_registers {old_vs1}]
if {[hangzo_logical_register_count $hangzo_hdmi_vs_source] != 1 ||
    [get_collection_size $hangzo_hdmi_vs_source] > 4 ||
    [get_collection_size $hangzo_palette_vs_sync1] != 1 ||
    [get_collection_size [get_registers {old_vs2}]] != 1} {
    error "Hangzo: HDMI vertical-sync synchronizer endpoints changed"
}
set_false_path -from $hangzo_hdmi_vs_source -to $hangzo_palette_vs_sync1

# Reset sources assert asynchronously. Their deassertion reaches functional
# state only through the following destination-domain release pipelines.
set hangzo_async_reset_targets [get_registers {
    reset_req_pll_pipe[*]
    *|game_reset_release[*]
    *|reset_source|release_pipe[*]
    ascal:ascal|i_reset_na_sync1 ascal:ascal|i_reset_na
    ascal:ascal|o_reset_na_sync1 ascal:ascal|o_reset_na
    ascal:ascal|avl_reset_na_sync1 ascal:ascal|avl_reset_na
}]
if {[hangzo_logical_register_count $hangzo_async_reset_targets] != 12} {
    error "Hangzo: expected twelve logical reset synchronizer stages including every fitted replica"
}
set hangzo_audio_reset_targets [get_registers {
    hangzo_clock_reset:audio_reset_sync|release_pipe[*]
    hangzo_clock_reset:audio_filter_reset_sync|release_pipe[*]
}]
if {[get_collection_size $hangzo_audio_reset_targets] != 4} {
    error "Hangzo: expected four audio-domain reset synchronizer stages"
}
set hangzo_reset_req_source [get_registers {reset_req}]
set hangzo_init_reset_source [get_registers {sysmem_lite:sysmem|init_reset_n}]
set hangzo_power_ready_source [get_keepers {*|power_ready}]
# The fit report shows the single init_reset_n source is physically duplicated
# once for routability; preserve both exact copies if the fitter has created it.
set hangzo_reset_req_source_count [get_collection_size $hangzo_reset_req_source]
set hangzo_init_reset_source_count [get_collection_size $hangzo_init_reset_source]
set hangzo_init_reset_source_logical_count [hangzo_logical_register_count $hangzo_init_reset_source]
set hangzo_power_ready_source_count [get_collection_size $hangzo_power_ready_source]
if {$hangzo_reset_req_source_count != 1 ||
    $hangzo_init_reset_source_count < 1 ||
    $hangzo_init_reset_source_count > 2 ||
    $hangzo_init_reset_source_logical_count != 1 ||
    $hangzo_power_ready_source_count != 1} {
    error "Hangzo: asynchronous reset source endpoints changed (reset_req=$hangzo_reset_req_source_count init_reset_n=$hangzo_init_reset_source_count logical_init_reset_n=$hangzo_init_reset_source_logical_count power_ready=$hangzo_power_ready_source_count)"
}
set_false_path -from $hangzo_reset_req_source -to $hangzo_async_reset_targets
set_false_path -from $hangzo_init_reset_source -to $hangzo_async_reset_targets
set_false_path -from $hangzo_power_ready_source -to $hangzo_async_reset_targets
set_false_path -from $hangzo_reset_req_source -to $hangzo_audio_reset_targets
set_false_path -from $hangzo_init_reset_source -to $hangzo_audio_reset_targets
set_false_path -from $hangzo_power_ready_source -to $hangzo_audio_reset_targets
set hangzo_audio_filter_reset_source [get_registers {areset}]
if {[get_collection_size $hangzo_audio_filter_reset_source] != 1} {
    error "Hangzo: expected one audio filter reconfiguration reset source"
}
set hangzo_audio_filter_reset_target [get_registers {
    hangzo_clock_reset:audio_filter_reset_sync|release_pipe[*]
}]
if {[get_collection_size $hangzo_audio_filter_reset_target] != 2} {
    error "Hangzo: expected two audio filter reset release stages"
}
set_false_path -from $hangzo_audio_filter_reset_source -to $hangzo_audio_filter_reset_target

# Destination-entry registers only; local stages and consumers stay timed.
set hangzo_framework_sync1 [get_registers {
    sysmem_lite:sysmem|ram1_reset_0
    sysmem_lite:sysmem|ram2_reset_0
    sysmem_lite:sysmem|vbuf_reset_0
    ascal:ascal|avl_write_meta ascal:ascal|avl_read_meta
    ascal:ascal|avl_o_vs_meta
    ascal:ascal|o_readack_meta ascal:ascal|o_readdataack_meta
    pll_hdmi_adj:pll_hdmi_adj|ivss_meta
    pll_hdmi_adj:pll_hdmi_adj|ovss_meta
    hangzo_pll_cfg_bridge:pll_config_cdc|done_meta
    hangzo_pll_cfg_bridge:pll_config_cdc|vs_meta
    hangzo_pll_cfg_bridge:pll_config_cdc|got_meta
    pal_vs_meta
    ascal:ascal|o_iendframe0_meta ascal:ascal|o_iendframe1_meta
    vs_d0 fb_vbl_meta hdmi_csync_meta
}]
if {[hangzo_logical_register_count $hangzo_framework_sync1] != 19} {error "Hangzo: framework entry synchronizer inventory changed"}
set_false_path -to $hangzo_framework_sync1
set hangzo_led_sync1 [get_registers {mcp23009:mcp23009|led_sync1[*]}]
if {[get_collection_size $hangzo_led_sync1] < 1 || [hangzo_logical_register_count $hangzo_led_sync1] > 3} {error "Hangzo: independent LED sampler inventory changed"}
set_false_path -to $hangzo_led_sync1

# Held packet banks: at least two destination periods settle before capture;
# overwrite follows acknowledgement through two source periods. The fastest
# source is 100MHz (20ns post-capture hold), data routing is bounded to 15ns.
# These are protocol-controlled captures, not simultaneous unrelated-clock
# edges. A nominal min-delay 0 would include their unrelated clock skew and
# demand artificial hold routing. Cut hold only on these exact payload banks;
# keep maximum setup and physical net-delay budgets, and all local FF holds.
proc hangzo_packet_hold_cut {from to} {
    if {![info exists ::hangzo_packet_hold_scope_probe] || !$::hangzo_packet_hold_scope_probe} {
        set_false_path -hold -from $from -to $to
    }
}
proc hangzo_constrain_packet {prefix width {budget 15.000} {minimum -1}} {
    set send [get_registers [list "${prefix}|send"]]
    set send_meta [get_registers [list "${prefix}|send_meta"]]
    set ack [get_registers [list "${prefix}|ack"]]
    set ack_meta [get_registers [list "${prefix}|ack_meta"]]
    foreach c [list $send $ack] {
        # Native fitting duplicates the source send FF for gain and scaler
        # packets. Include every physical copy while requiring one original
        # logical register; the two receiving synchronizer stages stay timed.
        if {[hangzo_logical_register_count $c] != 1} {error "Hangzo: packet handshake inventory changed $prefix"}
    }
    foreach stage {send_meta send_sync ack_meta ack_sync} {
        if {[get_collection_size [get_registers [list "${prefix}|$stage"]]] != 1} {
            error "Hangzo: packet synchronizer stage missing or replicated $prefix/$stage"
        }
    }
    set_false_path -from $send -to $send_meta
    set_false_path -from $ack -to $ack_meta
    set held [get_registers [format {%s|held[*]} $prefix]]
    set capture [get_registers [format {%s|dst_data[*]} $prefix]]
    if {$minimum < 0} {set minimum $width}
    set h [hangzo_logical_register_count $held];set c [hangzo_logical_register_count $capture]
    if {$h != $c || $h < $minimum || $h > $width} {error "Hangzo: packet width changed $prefix held=$h capture=$c"}
    set_max_delay -from $held -to $capture $budget
    hangzo_packet_hold_cut $held $capture
    set_net_delay -max $budget -from $held -to $capture
    lappend ::hangzo_delay_banks [list $prefix $held $capture $budget]
}
set ::hangzo_delay_banks [list]
hangzo_constrain_packet {hangzo_cdc_latest:audio_boost_cdc} 2
hangzo_constrain_packet {hangzo_cdc_latest:core_audio_cdc} 32
hangzo_constrain_packet {alsa:alsa|hangzo_cdc_latest:metadata_cdc} 61
hangzo_constrain_packet {hangzo_pll_cfg_bridge:pll_config_cdc|hangzo_cdc_latest:custom_cdc} 38
hangzo_constrain_packet {hangzo_cdc_latest:palette_config_cdc} 30
# The packet carries eight RTL bits. Native synthesis retains six: input
# buffer 1 (bits 5:4) has no live consumer in this progressive Hangzo build.
hangzo_constrain_packet {ascal:ascal|hangzo_cdc_latest:buffer_pointer_cdc} 6
# Native live-bit inventories, including the unused high framebuffer-base
# bits removed from the 243-bit video tuple. 10ns settles within two 148.5MHz periods.
hangzo_constrain_packet {hangzo_scaler_config:scaler_config_cdc|hangzo_cdc_latest:video_cdc} 213 10.000
hangzo_constrain_packet {hangzo_scaler_config:scaler_config_cdc|hangzo_cdc_latest:avalon_cdc} 33 15.000
hangzo_constrain_packet {ascal:ascal|hangzo_cdc_latest:frame_config_cdc} 30 10.000
hangzo_constrain_packet {ascal:ascal|hangzo_cdc_latest:poly_config_cdc} 2 10.000
hangzo_constrain_packet {osd:hdmi_osd|hangzo_cdc_latest:config_cdc} 52 10.000
hangzo_constrain_packet {osd:vga_osd|hangzo_cdc_latest:config_cdc} 52 10.000
hangzo_constrain_packet {shadowmask:HDMI_shadowmask|hangzo_cdc_latest:config_cdc} 11 10.000

# Scaler request payloads are captured only after the two-stage toggle chain
# and its registered edge detector. Write launches are separated by >=6 input
# clocks (107.142ns at the fixed 56MHz input). Read address is held until ACK.
# Only producer-data paths are bounded; Avalon-local address muxes stay timed.
foreach {source target width} {
    i_wadrs avl_wadrs 32 i_walt avl_walt 1
    o_adrs avl_radrs 32 o_rline avl_rline 1
} {
    if {$width == 1} {
        set from [get_registers "ascal:ascal|$source"]
        set to [get_registers "ascal:ascal|$target"]
    } else {
        set from [get_registers [format {ascal:ascal|%s[*]} $source]]
        set to [get_registers [format {ascal:ascal|%s[*]} $target]]
    }
    foreach c [list $from $to] {
        set count [hangzo_logical_register_count $c]
        if {$count < 1 || $count > $width} {error "Hangzo: scaler payload inventory changed $source/$target"}
    }
    set_max_delay -from $from -to $to 15.000
    hangzo_packet_hold_cut $from $to
    set_net_delay -max 15.000 -from $from -to $to
    lappend ::hangzo_delay_banks [list "scaler_$source" $from $to 15.000]
}
# Progressive input removes the interlaced write-line bit completely. Refuse
# an unreviewed live interlaced path instead of silently skipping it.
if {[get_collection_size [get_registers {ascal:ascal|i_wline ascal:ascal|avl_wline}]] != 0} {
    error "Hangzo: interlaced scaler write-line path became live"
}

# Acknowledged 128-bit telemetry mailbox. Capture is at least two clk_sys
# Video/HDMI input levels enter dedicated clk_100 two-stage synchronizers.
# Only first stages are cut; second stages and edge detectors stay timed.
set hangzo_metric_level_sync1 [get_registers {
    *|video_calc:video_calc|metric_vs_sync1
    *|video_calc:video_calc|metric_hs_sync1
    *|video_calc:video_calc|metric_de_sync1
    *|video_calc:video_calc|metric_hdmi_sync1
}]
if {[get_collection_size $hangzo_metric_level_sync1] != 4} {error "Hangzo: telemetry level synchronizers changed"}
set_false_path -to $hangzo_metric_level_sync1

# Acknowledged 128-bit telemetry mailbox. Capture is at least two clk_sys
# cycles after the source bank is held (35.714 ns), and the next overwrite
# is at least two 100 MHz cycles after destination capture (20 ns).
# Only the request/acknowledge first stages are asynchronous exceptions.
set hangzo_metric_req [get_registers {*|video_calc:video_calc|metric_req}]
set hangzo_metric_req_sync1 [get_registers {*|video_calc:video_calc|metric_req_sync1}]
set hangzo_metric_ack [get_registers {*|video_calc:video_calc|metric_ack}]
set hangzo_metric_ack_sys1 [get_registers {*|video_calc:video_calc|metric_ack_sys1}]
foreach collection [list $hangzo_metric_req $hangzo_metric_ack] {
    if {[hangzo_logical_register_count $collection] != 1 || [get_collection_size $collection] > 4} {error "Hangzo: telemetry source inventory changed"}
}
foreach collection [list $hangzo_metric_req_sync1 $hangzo_metric_ack_sys1 [get_registers {*|video_calc:video_calc|metric_req_sync2}] [get_registers {*|video_calc:video_calc|metric_ack_sys2}]] {
    if {[get_collection_size $collection] != 1} {error "Hangzo: telemetry control synchronizer changed"}
}
set_false_path -from $hangzo_metric_req -to $hangzo_metric_req_sync1
set_false_path -from $hangzo_metric_ack -to $hangzo_metric_ack_sys1
set hangzo_metric_hold [get_registers {*|video_calc:video_calc|metric_hold[*]}]
set hangzo_metric_snapshot [get_registers {*|video_calc:video_calc|metric_snapshot[*]}]
if {[get_collection_size $hangzo_metric_hold] != 128 || [get_collection_size $hangzo_metric_snapshot] != 128} {
    error "Hangzo: telemetry mailbox must retain exactly 128 source and capture bits"
}
set_max_delay -from $hangzo_metric_hold -to $hangzo_metric_snapshot 15.000
hangzo_packet_hold_cut $hangzo_metric_hold $hangzo_metric_snapshot
set_net_delay -max 15.000 -from $hangzo_metric_hold -to $hangzo_metric_snapshot
lappend ::hangzo_delay_banks [list telemetry $hangzo_metric_hold $hangzo_metric_snapshot 15.000]
source constraints/hangzo_packet_scope.tcl

# lowlat is a static HPS setting synchronized by pll_hdmi_adj. Only its path
# into the first synchronizer stage is asynchronous; the second stage and all
# PLL-control logic remain timed on FPGA_CLK1_50.
set hangzo_lowlat_source [get_registers {lowlat}]
set hangzo_lowlat_sync1 [get_registers {pll_hdmi_adj:pll_hdmi_adj|llena_sync1}]
if {[hangzo_logical_register_count $hangzo_lowlat_source] != 1 ||
    [get_collection_size $hangzo_lowlat_sync1] != 1} {
    error "Hangzo: lowlat synchronizer endpoints changed"
}
set_false_path -from $hangzo_lowlat_source -to $hangzo_lowlat_sync1
set_input_delay -clock hangzo_sdram_pad -max 10.000 $hangzo_sdram_data
set_input_delay -clock hangzo_sdram_pad -min 2.500 $hangzo_sdram_data
set_output_delay -clock hangzo_sdram_pad -max 3.500 $hangzo_sdram_data
set_output_delay -add_delay -clock hangzo_sdram_pad -min -2.800 $hangzo_sdram_data
set_output_delay -clock hangzo_sdram_pad -max 3.500 $hangzo_sdram_command
set_output_delay -add_delay -clock hangzo_sdram_pad -min -2.800 $hangzo_sdram_command
