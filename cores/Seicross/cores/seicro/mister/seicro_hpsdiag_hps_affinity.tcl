# Project-owned clock-affinity model for the fixed Template HPS MPFE wiring.
# Only a hard endpoint's unassociated clock samples are removed. Each real
# port clock, all fabric-side clocks, and local fabric paths stay timed.
source [file join [file dirname [info script]] seicro_hpsdiag_hps_pin_inventory.tcl]

proc seicro_hpsdiag_hps_prepare_affinity {} {
    global seicro_hpsdiag_root_name seicro_hpsdiag_hps_expected_pins seicro_hpsdiag_hps_affinity seicro_hpsdiag_hps_clocks
    set actual [list]
    foreach_in_collection pin [get_pins -compatibility_mode {*|f2sdram|*}] {
        lappend actual [get_pin_info -name $pin]
    }
    if {[lsort $actual] ne [lsort $seicro_hpsdiag_hps_expected_pins]} {
        error "Seicross diagnostic: native HPS pin inventory changed (actual=[llength $actual] expected=[llength $seicro_hpsdiag_hps_expected_pins])"
    }
    set seicro_hpsdiag_hps_clocks [dict create \
        0 [get_clocks {*|h2f_user0_clk}] \
        1 [get_clocks $seicro_hpsdiag_root_name] \
        2 [get_clocks {pll_audio*PLL_OUTPUT_COUNTER*divclk}]]
    set seen [list]
    foreach role {0 1 2} {
        set clock [dict get $seicro_hpsdiag_hps_clocks $role]
        if {[get_collection_size $clock] != 1} {error "Seicross diagnostic: nonunique HPS port-$role user clock"}
        lappend seen [get_clock_info -name $clock]
    }
    if {[llength [lsort -unique $seen]] != 3} {error "Seicross diagnostic: HPS client clock roles changed"}
    set grouped [dict create]
    foreach name $actual {
        set family [lindex [split $name |] end]
        regsub {\[[0-9]+\]$} $family "" family
        dict lappend grouped $family $name
    }
    set seicro_hpsdiag_hps_affinity [dict create]
    foreach family [lsort [dict keys $grouped]] {
        if {[regexp {^cmd_(data|valid|ready|port_clk)_([012])$} $family unused kind role]} {
            if {$kind eq "port_clk"} {set direction clock} elseif {$kind eq "ready"} {set direction output} else {set direction input}
        } elseif {[regexp {^(rd_data|rd_valid|rd_clk|wr_data|wr_clk)_([0123])$} $family unused kind lane]} {
            set role [lindex {0 0 1 2} $lane]
            if {$kind eq "rd_clk" || $kind eq "wr_clk"} {set direction clock} elseif {$kind eq "wr_data"} {set direction input} else {set direction output}
        } else {error "Seicross diagnostic: unclassified hard HPS pin family $family"}
        set names [dict get $grouped $family]
        set pins [get_pins -compatibility_mode $names]
        if {[get_collection_size $pins] != [llength $names]} {error "Seicross diagnostic: ambiguous HPS family $family"}
        dict set seicro_hpsdiag_hps_affinity $family [dict create role $role direction $direction pins $pins names $names]
    }
}

proc seicro_hpsdiag_hps_apply_affinity {} {
    global seicro_hpsdiag_hps_affinity seicro_hpsdiag_hps_clocks
    foreach family [dict keys $seicro_hpsdiag_hps_affinity] {
        set entry [dict get $seicro_hpsdiag_hps_affinity $family]
        set direction [dict get $entry direction]
        if {$direction eq "clock"} {continue}
        set associated [dict get $seicro_hpsdiag_hps_clocks [dict get $entry role]]
        set foreign [remove_from_collection [get_clocks *] $associated]
        set pins [dict get $entry pins]
        if {$direction eq "input"} {
            # Only the hard capture clock can be an unassociated model sample.
            set_false_path -to $foreign -through $pins
        } else {
            # Only the hard launch clock can be an unassociated model sample.
            set_false_path -from $foreign -through $pins
        }
    }
}

proc seicro_hpsdiag_hps_write_inventory {path} {
    global seicro_hpsdiag_hps_affinity seicro_hpsdiag_hps_clocks
    set f [open $path w]
    puts $f "family\trole\tdirection\tclock\tpin"
    foreach family [lsort [dict keys $seicro_hpsdiag_hps_affinity]] {
        set e [dict get $seicro_hpsdiag_hps_affinity $family]
        set role [dict get $e role]
        set clock [get_clock_info -name [dict get $seicro_hpsdiag_hps_clocks $role]]
        foreach name [lsort [dict get $e names]] {puts $f "$family\t$role\t[dict get $e direction]\t$clock\t$name"}
    }
    close $f
}

proc seicro_hpsdiag_hps_observe_required {path} {
    global seicro_hpsdiag_hps_affinity seicro_hpsdiag_hps_clocks
    set f [open $path w]
    puts $f "family\tdirection\tcheck\tfrom\tto\tfrom_clock\tto_clock\tslack_ns"
    set limit [expr {[get_collection_size [get_keepers *]]+1}]
    set hard {^sysmem_lite:sysmem\|sysmem_HPS_fpga_interfaces:fpga_interfaces\|f2sdram~FF_[0-9]+$}
    foreach family [lsort [dict keys $seicro_hpsdiag_hps_affinity]] {
        set e [dict get $seicro_hpsdiag_hps_affinity $family]
        set direction [dict get $e direction]
        if {$direction eq "clock"} {continue}
        set associated [dict get $seicro_hpsdiag_hps_clocks [dict get $e role]]
        set pins [dict get $e pins]
        foreach_in_collection other_id [get_clocks *] {
            set other [get_clocks [list [get_clock_info -name $other_id]]]
            if {[get_collection_size $other] != 1} {error "Ambiguous HPS observer clock"}
            foreach check {setup hold} {
                if {$direction eq "input"} {
                    set paths [get_timing_paths -$check -from_clock $other -to_clock $associated -through $pins -npaths $limit -nworst 1]
                } else {
                    set paths [get_timing_paths -$check -from_clock $associated -to_clock $other -through $pins -npaths $limit -nworst 1]
                }
                if {[get_collection_size $paths] >= $limit} {error "HPS required endpoint query truncated"}
                foreach_in_collection p $paths {
                    set from [get_node_info -name [get_path_info -from $p]]
                    set to [get_node_info -name [get_path_info -to $p]]
                    set fh [regexp $hard $from]; set th [regexp $hard $to]
                    if {$fh && $th} {continue}
                    if {($direction eq "input" && !$th) || ($direction eq "output" && !$fh)} {
                        error "Unexpected HPS pin endpoint topology: $family $from -> $to"
                    }
                    puts $f "$family\t$direction\t$check\t$from\t$to\t[get_clock_info -name [get_path_info -from_clock $p]]\t[get_clock_info -name [get_path_info -to_clock $p]]\t[get_path_info -slack $p]"
                }
            }
        }
    }
    close $f
}

proc seicro_hpsdiag_hps_compare_required {baseline candidate} {
    global seicro_hpsdiag_hps_affinity
    set old [dict create]
    set f [open $baseline r]; gets $f header
    while {[gets $f line]>=0} {
        set r [split $line \t]
        set key [list [lindex $r 0] [lindex $r 1] [lindex $r 2] [lindex $r 4] [lindex $r 5] [lindex $r 6]]
        if {[dict exists $old $key]} {error "Duplicate required baseline endpoint"}
        dict set old $key $r
    }
    close $f
    set seen [dict create];set f [open $candidate r];gets $f header
    while {[gets $f line]>=0} {
        set r [split $line \t]
        set key [list [lindex $r 0] [lindex $r 1] [lindex $r 2] [lindex $r 4] [lindex $r 5] [lindex $r 6]]
        if {![dict exists $old $key] || [dict exists $seen $key]} {error "Required HPS interface endpoint coverage changed"}
        dict set seen $key 1;set before [dict get $old $key]
        if {abs([lindex $before 7]-[lindex $r 7])>0.0001} {error "Required HPS interface slack changed"}
        if {[lindex $before 3] ne [lindex $r 3]} {
            set from [get_keepers [list [lindex $before 3]]]
            set to [get_keepers [list [lindex $before 4]]]
            set check [lindex $before 2]
            set paths [get_timing_paths -$check -from $from -to $to -from_clock [get_clocks [list [lindex $before 5]]] -to_clock [get_clocks [list [lindex $before 6]]] -through [dict get $seicro_hpsdiag_hps_affinity [lindex $before 0] pins] -npaths 1 -nworst 1]
            if {[get_collection_size $paths] != 1} {error "Original required HPS tied source was removed"}
            foreach_in_collection p $paths {
                if {abs([get_path_info -slack $p]-[lindex $before 7])>0.0001} {error "Original HPS tied-source slack changed"}
            }
        }
    }
    close $f
    if {[dict size $seen] != [dict size $old]} {error "Required HPS interface endpoint coverage changed"}
    return [dict size $seen]
}

seicro_hpsdiag_hps_prepare_affinity
if {![info exists ::seicro_hpsdiag_hps_scope_probe] || !$::seicro_hpsdiag_hps_scope_probe} {seicro_hpsdiag_hps_apply_affinity}
