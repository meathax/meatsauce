# Manual analysis helper: worst setup paths per slow corner. Not wired into the QSF; run it from
# quartus_sta (or temporarily add `set_global_assignment -name TIMEQUEST_REPORT_SCRIPT scripts/report_worst_paths.tcl`).
# Analysis-only TimeQuest report hook (TIMEQUEST_REPORT_SCRIPT): worst setup paths
# per slow operating condition. No effect on synthesis, fit or assembler.
set out [file join [pwd] sim results timing worst-paths]
file mkdir $out
foreach_in_collection op [get_available_operating_conditions -all] {
    set name [get_operating_conditions_info -display_name $op]
    if {![string match "Slow*" $name]} continue
    regsub -all {[^[:alnum:]_.-]} $name _ tag
    set_operating_conditions $op
    update_timing_netlist
    report_timing -setup -npaths 40 -detail summary -file [file join $out "${tag}-summary.rpt"]
    report_timing -setup -npaths 5 -detail full_path -file [file join $out "${tag}-full.rpt"]
}
