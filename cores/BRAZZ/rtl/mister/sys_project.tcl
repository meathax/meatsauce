# Load the pristine upstream pin/settings Tcl with one explicit QIP substitution.
set cs_sys_stream [open sys/sys.tcl r]
set cs_sys_body [read $cs_sys_stream]
close $cs_sys_stream
set cs_sys_qip_line {set_global_assignment -name QIP_FILE sys/sys.qip}
if {[regexp -all -line {^set_global_assignment -name QIP_FILE sys/sys.qip$} $cs_sys_body] != 1} {
    error "upstream sys Tcl QIP selection changed; review project override"
}
eval [string map [list $cs_sys_qip_line {set_global_assignment -name QIP_FILE rtl/mister/sys_project.qip}] $cs_sys_body]
unset cs_sys_stream cs_sys_body cs_sys_qip_line
