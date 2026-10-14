# Chain the existing MiSTer build-ID hook and the MeatCore Credits generator.
set credits_project_root [file dirname [file normalize [info script]]]
source [file join $credits_project_root sys build_id.tcl]
set ::env(CREDITS_COLUMNS) 48
source [file join $credits_project_root credits preflow.tcl]
