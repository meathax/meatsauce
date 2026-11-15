# Pre-flow hook for the host core. sys/sys.tcl assigns sys/build_id.tcl; files.qip assigns this file instead and sources both,
# preserving the platform script unchanged and adding the credits generator (credits/preflow.tcl, columns 24 unless CREDITS_COLUMNS).
set host_root [file dirname [file normalize [info script]]]
source [file join $host_root sys build_id.tcl]
source [file join $host_root credits preflow.tcl]
