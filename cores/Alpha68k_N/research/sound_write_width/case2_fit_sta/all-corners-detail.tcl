# SPDX-License-Identifier: GPL-2.0-or-later
# Adapted from the reviewed QuartusFast all-corners collector. STA observation only.
# API: Intel/Altera Quartus II Scripting Reference Manual, July 2013.
# https://cdrdv2-public.intel.com/654662/tclscriptrefmnl.pdf
load_package project
load_package sta
if {[info exists quartus(args)]} {set collector_args $quartus(args)} else {set collector_args $argv}
if {[llength $collector_args] != 3} {error "Expected project, revision and destination"}
set project [lindex $collector_args 0]
set revision [lindex $collector_args 1]
set destination [file normalize [lindex $collector_args 2]]
file mkdir $destination
project_open -revision $revision $project
create_timing_netlist
read_sdc
set group_patterns [list \
    [list game {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    [list hdmi {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    [list audio {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    [list spi {spi_sck}] [list hdmi_i2c {hdmi_sck}] \
    [list hps {*|h2f_user0_clk}] [list ref1 {FPGA_CLK1_50}] \
    [list ref2 {FPGA_CLK2_50}] [list ref3 {FPGA_CLK3_50}]]
set groups [open [file join $destination inherited_clock_groups.txt] w]
foreach entry $group_patterns {
    set label [lindex $entry 0]
    set pattern [lindex $entry 1]
    set matches [get_clocks $pattern]
    puts $groups "$label pattern=$pattern count=[get_collection_size $matches]"
    foreach_in_collection clock $matches {puts $groups "  [get_clock_info -name $clock]"}
}
close $groups
set csv [open [file join $destination corners.csv] w]
puts $csv "corner,model,temperature,voltage,check,worst_slack_ns,paths"
set number 0
foreach_in_collection operating [get_available_operating_conditions -all] {
    incr number
    set name [get_operating_conditions_info -display_name $operating]
    set model [get_operating_conditions_info -model $operating]
    set temperature [get_operating_conditions_info -temperature $operating]
    set voltage [get_operating_conditions_info -voltage $operating]
    set_operating_conditions $operating
    update_timing_netlist
    set folder [file join $destination corner_$number]
    file mkdir $folder
    set info [open [file join $folder condition.txt] w]
    puts $info "$name\nmodel=$model temperature=$temperature voltage=$voltage"
    close $info
    foreach type {setup hold recovery removal} {
        set paths [get_timing_paths -$type -npaths 1]
        set count [get_collection_size $paths]
        set slack "NA"
        foreach_in_collection path $paths {set slack [get_path_info -slack $path]}
        puts $csv "\"$name\",$model,$temperature,$voltage,$type,$slack,$count"
        report_timing -$type -npaths 10 -detail full_path -file [file join $folder $type.txt]
    }
    foreach_in_collection clock [get_clocks *] {
        set clock_name [get_clock_info -name $clock]
        set domain ""
        if {$clock_name eq {emu|pll|pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}} {set domain game}
        if {$clock_name eq {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}} {set domain audio}
        if {$domain ne ""} {
            foreach type {setup hold} {
                report_timing -$type -from_clock $clock -to_clock $clock -npaths 10 -detail full_path -file [file join $folder same_${domain}_${type}.txt]
            }
        }
    }
    report_min_pulse_width -file [file join $folder min_pulse_width.txt]
    report_clocks -file [file join $folder clocks.txt]
    report_ucp -file [file join $folder unconstrained.txt]
    puts "CORNER $number: $name"
    flush $csv
}
close $csv
if {$number == 0} {error "No operating conditions found"}
delete_timing_netlist
project_close -dont_export_assignments
puts "Collected $number device operating conditions."
