# Optional Quartus hook, run before compile to rebuild the internal ROMs.
# If the host has an existing PRE_FLOW_SCRIPT_FILE, source this file from it.
set credits_root [file dirname [file normalize [info script]]]
set generator [file join $credits_root tools generate.py]
set source_names [file join $credits_root .. .. credits.txt]
set output_dir [file join $credits_root generated]
set interpreter python
if {[info exists ::env(CREDITS_PYTHON)]} { set interpreter $::env(CREDITS_PYTHON) }
set columns 48
if {[info exists ::env(CREDITS_COLUMNS)]} { set columns $::env(CREDITS_COLUMNS) }
if {[catch {exec $interpreter $generator --input $source_names --output $output_dir --columns $columns} result]} {
    post_message -type error "Credits generation failed: $result"
    error $result
}
post_message -type info $result
