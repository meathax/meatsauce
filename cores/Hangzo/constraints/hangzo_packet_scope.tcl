# Held payloads remain setup/net-delay constrained. Only their protocol-proved
# simultaneous-edge hold check is waived; every physical capture stays visible.
proc hangzo_packet_observe {path require_cut} {
    set f [open $path w]
    puts $f "bank\ttarget\tslack_ns\thold_paths"
    set result [dict create]
    foreach bank $::hangzo_delay_banks {
        lassign $bank name source target budget
        set holds [get_collection_size [get_timing_paths -hold -from $source -to $target -npaths 1]]
        if {$require_cut && $holds != 0} {error "Hangzo: packet hold cut missing $name"}
        set expected [dict create]
        foreach_in_collection r $target {dict set expected [get_object_info -name $r] 1}
        set seen [dict create]
        foreach_in_collection p [get_timing_paths -setup -from $source -to $target -npaths 10000 -nworst 1] {
            set to [get_node_info -name [get_path_info -to $p]]
            set slack [get_path_info -slack $p]
            dict set seen $to 1
            dict set result [list $name $to] $slack
            puts $f "$name\t$to\t$slack\t$holds"
        }
        if {[lsort [dict keys $expected]] ne [lsort [dict keys $seen]]} {
            error "Hangzo: packet setup coverage changed $name"
        }
    }
    close $f
    return $result
}
proc hangzo_packet_compare {before after} {
    if {[dict size $before] == 0 || [lsort [dict keys $before]] ne [lsort [dict keys $after]]} {
        error "Hangzo: packet setup coverage changed"
    }
    foreach key [dict keys $before] {
        if {abs([dict get $before $key]-[dict get $after $key])>0.001} {
            error "Hangzo: packet setup slack changed $key"
        }
    }
    return [dict size $after]
}
