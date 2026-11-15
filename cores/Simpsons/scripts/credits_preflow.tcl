# Preserve stock build identification and regenerate the embedded names ROM.
if {![info exists ::env(CREDITS_PYTHON)] && [info exists ::env(USERPROFILE)]} {
    set taskCreditsPython [file join $::env(USERPROFILE) .cache codex-runtimes codex-primary-runtime dependencies python python.exe]
    if {[file isfile $taskCreditsPython]} {set ::env(CREDITS_PYTHON) $taskCreditsPython}
}
source sys/build_id.tcl
source credits/preflow.tcl
