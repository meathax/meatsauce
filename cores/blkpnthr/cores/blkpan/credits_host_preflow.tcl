# Preserve the platform build ID hook and regenerate the embedded names.
set core_root [file dirname [file normalize [info script]]]
source [file join $core_root .. .. modules jtframe target mister hdl sys build_id.tcl]
source [file join $core_root credits preflow.tcl]
