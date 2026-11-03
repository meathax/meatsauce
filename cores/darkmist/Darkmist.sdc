source [file join [file dirname [info script]] constraints external-final complete-check.sdc]
# Optional development-only refinement. Release requires independently closed current timing.
set dm_postfit_contract [file join [file dirname [info script]] constraints postfit-io.sdc]
if {[file exists $dm_postfit_contract]} {source $dm_postfit_contract}
