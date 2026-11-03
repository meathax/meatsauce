# Validation only: no timestamps, file generation or source rewrites.
source rtl/framework/platform/build_id_contract.tcl
set pwb_header [open build_id.v rb]
set pwb_actual_build_id [read $pwb_header]
close $pwb_header
set pwb_expected_build_id [binary format H* $pwb_build_id_bytes_hex]
if {$pwb_actual_build_id ne $pwb_expected_build_id} {
    error "PWB sealed build_id.v differs from its pre-inventory contract"
}
if {[file exists rtl/framework/build_id.v]} {
    error "PWB ambiguous legacy build header must not be present"
}
puts "PWB immutable build identity validated: $pwb_build_date_ymd $pwb_build_id_sha256"
