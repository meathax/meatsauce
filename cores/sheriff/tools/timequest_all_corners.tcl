# SPDX-License-Identifier: GPL-2.0-or-later
# Run with quartus_sta -t <this file> <project> <report-directory>, from a fitted
# source snapshot. STA only: never runs synthesis, fitter, assembler or conversion.
# API reference: Intel/Altera Quartus II Scripting Reference Manual, July 2013,
# https://cdrdv2-public.intel.com/654662/tclscriptrefmnl.pdf (quartus::sta).
load_package project
load_package sta
if {[llength $argv] != 2} { error "Expected project and report-directory arguments" }
set project [lindex $argv 0]
set destination [file normalize [lindex $argv 1]]
file mkdir $destination
project_open $project
create_timing_netlist
read_sdc
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
    report_min_pulse_width -file [file join $folder min_pulse_width.txt]
    report_clocks -file [file join $folder clocks.txt]
    report_ucp -file [file join $folder unconstrained.txt]
    puts "CORNER $number: $name"
    flush $csv
}
close $csv
if {$number == 0} {error "No operating conditions found; not a timing pass"}
delete_timing_netlist
project_close
puts "Collected $number device operating conditions. Inspect all timing and unconstrained-path reports; collection is not acceptance."
