# Exact K051733 operand RAM -> registered read-result contract, same 48 MHz.
# Accepted write-Q and read-Q are mutually exclusive; Q->Q >=8 clocks,
# reset->first Q >=9. Conservative 4/3 applies only to operand bytes0..5.
# No timing exception on CPU address/select, LFSR, timer, restore or latch fanout.
set pwb_math_sources {}
set pwb_math_seen [dict create]
set pwb_math_source_patterns {}
set pwb_math_source_names {}
foreach_in_collection reg [get_registers -nowarn {*|u_bus|math|*}] {
    set name [get_node_info -name $reg]
    set leaf [lindex [split $name |] end]
    if {[regexp {^ram\[([0-9]+)\]\[([0-7])\]$} $leaf unused byte bit]} {
        if {$byte > 31} {error "PWB unknown operand RAM byte: $name"}
        if {$byte < 6} {
            lappend pwb_math_sources $reg
            # Q17 parses a list of patterns; single bracket escapes do not survive.
            # Match bracket positions narrowly, then require the exact original IDs/names.
            lappend pwb_math_source_patterns [string map {[ ? ] ?} $name]
            lappend pwb_math_source_names $name
            dict set pwb_math_seen "$byte,$bit" 1
        }
    } elseif {![regexp {^(lfsr|timer|pulse)(\[[0-9]+\])?$|^vb_old$} $leaf]} {
        error "PWB unknown/retimed K051733 register requires provenance: $name"
    }
}
if {[dict size $pwb_math_seen] != 48 || [llength $pwb_math_sources] != 48} {error "PWB math operand coverage is not all48 source bits"}
set pwb_math_dest [get_registers -nowarn {*|u_bus|math_read_data*}]
set pwb_math_dst_seen [dict create]
foreach_in_collection reg $pwb_math_dest {
    set name [get_node_info -name $reg]
    if {![regexp {\|math_read_data\[([0-7])\]$} $name unused bit]} {
        error "PWB unknown math read-latch alias: $name"
    }
    dict set pwb_math_dst_seen $bit 1
}
if {[dict size $pwb_math_dst_seen] != 8 || [get_collection_size $pwb_math_dest] != 8} {error "PWB math read-latch coverage is not all8 bits"}
set pwb_math_source_collection [get_registers -nowarn $pwb_math_source_patterns]
if {[get_collection_size $pwb_math_source_collection] != [llength $pwb_math_sources]} {error "PWB exact operand collection changed during resolution"}
set pwb_math_resolved_ids {}
set pwb_math_resolved_names {}
foreach_in_collection reg $pwb_math_source_collection {
    lappend pwb_math_resolved_ids $reg
    lappend pwb_math_resolved_names [get_node_info -name $reg]
}
if {[lsort $pwb_math_resolved_ids] ne [lsort $pwb_math_sources] ||
    [lsort $pwb_math_resolved_names] ne [lsort $pwb_math_source_names]} {
    error "PWB exact operand identities changed during resolution"
}
set_multicycle_path -setup 4 -from $pwb_math_source_collection -to $pwb_math_dest
set_multicycle_path -hold 3 -from $pwb_math_source_collection -to $pwb_math_dest
puts "PWB_MATH_EXACT operands=[llength $pwb_math_sources] logical_bits=48 read_bits=8 setup=4 hold=3"
