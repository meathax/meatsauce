# Preserve framework build identity before regenerating the native credits ROM.
set alpha68kn_root [file dirname [file normalize [info script]]]
source [file join $alpha68kn_root sys build_id.tcl]
set ::env(CREDITS_COLUMNS) 32
source [file join $alpha68kn_root credits preflow.tcl]
