# Preserve MiSTer's build timestamp while refreshing the embedded credits ROM.
set core_root [file dirname [file dirname [file normalize [info script]]]]
source [file join $core_root sys build_id.tcl]
source [file join $core_root credits preflow.tcl]
