# Routed timing only: no assembler, conversion, or RBF generation.
package require ::quartus::project
package require ::quartus::sta
set project [lindex $quartus(args) 0]
set out [lindex $quartus(args) 1]
if {[llength $quartus(args)] ni {2 3} || $project eq "" || $out eq ""} {
    error "Usage: timing_audit.tcl project output-directory ?constraint-overlay?"
}
set overlay [lindex $quartus(args) 2]
if {$overlay ne "" && ![file isfile $overlay]} {error "Missing constraint overlay: $overlay"}
file mkdir $out
project_open $project
create_timing_netlist
read_sdc
if {$overlay ne ""} {read_sdc $overlay}
update_timing_netlist
if {$overlay ne "" && [get_collection_size [get_clocks -nowarn ZT_HDMI_SCALE_CLK]] != 1} {
    error "Constraint overlay did not create the required forwarded HDMI clock"
}
report_clocks -file "$out/clocks.rpt"
report_ucp -file "$out/unconstrained.rpt"
set models {}
foreach_in_collection op [get_available_operating_conditions -all] {
    lappend models [list [get_operating_conditions_info -display_name $op] \
        [get_operating_conditions_info -model $op] \
        [get_operating_conditions_info -voltage $op] \
        [get_operating_conditions_info -temperature $op]]
}
delete_timing_netlist
set output [open "$out/slacks.tsv" w]
puts $output "corner\tanalysis\tslack_ns\tfrom\tto"
set inventory [open "$out/models.tsv" w]
puts $inventory "corner\tmodel\tvoltage_mv\ttemperature_c"
foreach condition $models {
    lassign $condition label model voltage temperature
    puts $inventory "$label\t$model\t$voltage\t$temperature"
}
flush $inventory
set violations [open "$out/violations.tsv" w]
puts $violations "corner\tanalysis\tslack_ns\tfrom\tto"
set failed 0
set corners 0
set pin_delays [open "$out/pin_delays.tsv" w]
puts $pin_delays "corner\tinterface\tdata_delay_ns\tfrom\tto"
set interfaces [open "$out/interfaces.tsv" w]
puts $interfaces "corner\tinterface\tanalysis\tslack_ns"
foreach condition $models {
    incr corners
    lassign $condition label model voltage temperature
    regsub -all {[^[:alnum:]_.-]} $label _ tag
    # Recreating each netlist avoids Quartus 17 HPS corner-switch annotation
    # failures. -force_dat calculates delays for the actual routed design.
    create_timing_netlist -model $model -voltage $voltage \
        -temperature $temperature -force_dat
    read_sdc
    if {$overlay ne ""} {read_sdc $overlay}
    update_timing_netlist
    check_timing -include {loops latches pll_cross_check no_clock multiple_clock generated_clock uncertainty
        partial_multicycle multicycle_consistency partial_min_max_delay
        io_min_max_delay_consistency no_input_delay no_output_delay
        partial_input_delay partial_output_delay} -file "$out/${tag}_constraints.rpt"
    if {[get_collection_size [get_clocks -nowarn ZT_HDMI_SCALE_CLK]] == 1} {
        set zt_hdmi_data [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
        set zt_audio_pin_data [get_ports {HDMI_I2S HDMI_LRCLK HDMI_SCLK USER_IO[2] USER_IO[4] USER_IO[5] SDCD_SPDIF}]
        foreach clock {ZT_HDMI_DIRECT_CLK ZT_HDMI_SCALE_CLK} {
            foreach type {setup hold} {
                set paths [get_timing_paths -$type -to $zt_hdmi_data -to_clock [get_clocks $clock] -npaths 1]
                if {[get_collection_size $paths] == 0} {error "HDMI $clock $type has no timed data paths"}
                foreach_in_collection path $paths {
                    set slack [get_path_info -slack $path]
                    puts $interfaces "$label\t$clock\t$type\t$slack"
                    if {$slack < 0} {set failed 1}
                }
                report_timing -$type -to $zt_hdmi_data -to_clock [get_clocks $clock] \
                    -npaths 2 -detail full_path -file "$out/${tag}_${clock}_${type}.rpt"
            }
        }
        set ram_dq [get_ports {SDRAM_DQ[*]}]
        # Same capture registers as ZeroTeam.sdc zt_sdram_capture_regs (donor capture, 88fd6d5).
        set ram_capture [get_registers {*|sdram:memory|dout[*]}]
        set ram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
        foreach direction {READ OUTPUT} {
            if {$direction eq "READ"} {
                set selectors [list -from $ram_dq -to $ram_capture]
            } else {
                set selectors [list -to $ram_outputs -to_clock [get_clocks ZT_SDRAM_CLK]]
            }
            foreach type {setup hold} {
                set paths [get_timing_paths -$type {*}$selectors -npaths 1]
                if {[get_collection_size $paths] == 0} {error "SDRAM $direction $type has no timed paths"}
                foreach_in_collection path $paths {
                    set slack [get_path_info -slack $path]
                    puts $interfaces "$label\tZT_SDRAM_$direction\t$type\t$slack"
                    if {$slack < 0} {set failed 1}
                }
                report_timing -$type {*}$selectors -npaths 2 -detail full_path \
                    -file "$out/${tag}_SDRAM_${direction}_${type}.rpt"
            }
        }
        # Quartus 17 max/min delays include clock latency. Check actual
        # cell + route delay as well, so the 20 ns interface bound is exact.
        foreach spec [list [list i2c_input -from [get_ports IO_SDA]] \
                           [list i2c_output -to [get_ports {IO_SDA IO_SCL}]] \
                           [list audio_output -to $zt_audio_pin_data]] {
            set paths [get_timing_paths -setup -npaths 200 -nworst 1 {*}[lrange $spec 1 end]]
            if {[get_collection_size $paths] == 0 || [get_collection_size $paths] >= 200} {
                error "Missing or truncated [lindex $spec 0] path inventory"
            }
            foreach_in_collection path $paths {
                set delay [get_path_info -data_delay $path]
                puts $pin_delays "$label\t[lindex $spec 0]\t$delay\t[get_node_info -name [get_path_info -from $path]]\t[get_node_info -name [get_path_info -to $path]]"
                if {$delay > 20.0} {set failed 1}
            }
        }
    }
    foreach type {setup hold recovery removal} {
        set paths [get_timing_paths -$type -npaths 1]
        if {[get_collection_size $paths] == 0} {
            error "Missing $type timing results for $label"
        }
        foreach_in_collection path $paths {
            set slack [get_path_info -slack $path]
            puts $output "$label\t$type\t$slack\t[get_node_info -name [get_path_info -from $path]]\t[get_node_info -name [get_path_info -to $path]]"
            if {$slack < 0} {set failed 1}
        }
        report_timing -$type -npaths 10 -nworst 10 -detail full_path \
            -file "$out/${tag}_${type}.rpt"
        foreach_in_collection path [get_timing_paths -$type -npaths 200 -nworst 1] {
            set slack [get_path_info -slack $path]
            if {$slack < 0} {
                puts $violations "$label\t$type\t$slack\t[get_node_info -name [get_path_info -from $path]]\t[get_node_info -name [get_path_info -to $path]]"
            }
        }
    }
    report_min_pulse_width -nworst 10 -detail full_path -file "$out/${tag}_pulse_width.rpt"
    set pulse_file [open "$out/${tag}_pulse_width.rpt" r]
    set pulse_text [read $pulse_file]
    close $pulse_file
    if {![regexp {Worst case slack is\s+(-?[\d.]+)} $pulse_text -> pulse_slack]} {
        error "Missing pulse-width slack for $label"
    }
    puts $output "$label\tpulse_width\t$pulse_slack\t\t"
    if {$pulse_slack < 0} {set failed 1}
    flush $output
    flush $inventory
    flush $violations
    puts "CORNER_COMPLETE $label negative_slack=$failed"
    delete_timing_netlist
    # Collect every corner before rejecting a failed fit, so one repair can
    # address the complete set of setup, hold and interface failures.
}
close $output
close $inventory
close $violations
close $pin_delays
close $interfaces
project_close -dont_export_assignments
puts "TIMING_AUDIT corners=$corners negative_path_slack=$failed"
if {$corners == 0 || $failed} {error "Timing closure is not established"}
# The caller must additionally enforce constraint and interface coverage.
