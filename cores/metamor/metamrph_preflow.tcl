source sys/build_id.tcl
# Generated ROMs are committed build inputs. Optional regeneration uses an
# explicitly selected working Python, preserving the host's normal build hook.
if {[info exists ::env(CREDITS_PYTHON)]} {
    set ::env(CREDITS_COLUMNS) 40
    source credits/preflow.tcl
}
