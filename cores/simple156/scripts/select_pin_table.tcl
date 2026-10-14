# QSF accepts assignments and source directives; conditional Tcl belongs here.
if {[get_current_revision] eq "OSMAN_dual"} {
    source sys/sys_dual_sdram.tcl
} else {
    source sys/sys_analog.tcl
}
