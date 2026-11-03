# Explicit registers whose functional updates use the same MCU CE.
# Minimum6 master clocks at48MHz including pause/reset and guarded mode changes.
# Use only2 setup clocks; hold-end1 restores the original same-clock hold edge.
# Full-rate ROM-address, IRQ/timer, CPU, video and SDRAM endpoints excluded.
set dec8_mcu_ce_patterns {}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|a*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|a*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|a* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|a*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|b*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|b*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|b* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|b*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|psw*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|psw*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|psw* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|psw*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|sp*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|sp*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|sp* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|sp*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|dptr*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 16} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|dptr*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|dptr* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|dptr*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|pc*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 16} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|pc*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|pc* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|pc*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|ir*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|ir*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|ir* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|ir*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|op1*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|op1*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|op1* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|op1*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|op2*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|op2*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|op2* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|op2*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|md*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|md*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|md* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|md*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|ea*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|ea*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|ea* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|ea*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|lhs*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|lhs*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|lhs* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|lhs*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_regs|rhs*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|u_mcu|u_mcu|u_regs|rhs*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_regs|rhs* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_regs|rhs*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|p0_ext*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|p0_ext*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|p0_ext* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|p0_ext*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|p1_ext*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|p1_ext*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|p1_ext* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|p1_ext*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|p0_force*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|p0_force*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|p0_force* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|p0_force*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|mcu_p2_prev*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|mcu_p2_prev*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|mcu_p2_prev* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|mcu_p2_prev*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|mcu_return*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 16} {error {Unexpected MCU CE endpoint cardinality: emu|board|u_sys|mcu_return*}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|mcu_return* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|mcu_return*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|p0*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality p0}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|p0* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|p0*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|p1*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality p1}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|p1* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|p1*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|p2*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality p2}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|p2* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|p2*}
set dec8_p3_candidates [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|p3*}]
set dec8_p3_names {}
foreach_in_collection dec8_p3_node $dec8_p3_candidates {
    set dec8_p3_native [get_node_info -name $dec8_p3_node]
    set dec8_p3_leaf [lindex [split $dec8_p3_native |] end]
    if {[regexp {^p3\[[0-7]\]$} $dec8_p3_leaf]} {
        lappend dec8_p3_names "emu|board|u_sys|u_mcu|u_mcu|u_periph|$dec8_p3_leaf"
    } else {puts "DEC8_MCU_SFR_P3_EXCLUDED $dec8_p3_native"}
}
set dec8_mcu_ce_one [get_registers $dec8_p3_names]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality p3}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|p3* $dec8_mcu_ce_count"
foreach dec8_p3_exact $dec8_p3_names {lappend dec8_mcu_ce_patterns $dec8_p3_exact}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|pcon*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality pcon}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|pcon* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|pcon*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|tcon*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality tcon}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|tcon* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|tcon*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|tmod*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality tmod}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|tmod* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|tmod*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|tl0*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality tl0}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|tl0* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|tl0*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|tl1*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality tl1}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|tl1* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|tl1*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|th0*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality th0}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|th0* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|th0*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|th1*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality th1}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|th1* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|th1*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|scon*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality scon}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|scon* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|scon*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|sbuf_rx*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality sbuf_rx}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|sbuf_rx* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|sbuf_rx*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|ie*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality ie}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|ie* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|ie*}
set dec8_mcu_ce_one [get_registers {emu|board|u_sys|u_mcu|u_mcu|u_periph|ip*}]
set dec8_mcu_ce_count [get_collection_size $dec8_mcu_ce_one]
if {$dec8_mcu_ce_count < 1 || $dec8_mcu_ce_count > 8} {error {Unexpected MCU SFR cardinality ip}}
puts "DEC8_MCU_CE_FIELD emu|board|u_sys|u_mcu|u_mcu|u_periph|ip* $dec8_mcu_ce_count"
lappend dec8_mcu_ce_patterns {emu|board|u_sys|u_mcu|u_mcu|u_periph|ip*}
set dec8_mcu_ce_domain [get_registers $dec8_mcu_ce_patterns]
puts "DEC8_MCU_CE_DOMAIN_COUNT [get_collection_size $dec8_mcu_ce_domain]"
foreach_in_collection dec8_mcu_ce_node $dec8_mcu_ce_domain {puts "DEC8_MCU_CE_NODE [get_node_info -name $dec8_mcu_ce_node]"}
set_multicycle_path -setup -end 2 -from $dec8_mcu_ce_domain -to $dec8_mcu_ce_domain
set_multicycle_path -hold -end 1 -from $dec8_mcu_ce_domain -to $dec8_mcu_ce_domain
