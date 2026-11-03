# Exact E-only register whitelist, minimum accepted E spacing12 at48MHz.
# Reset/phase coupling and sub-reset slot proof: CPU_E_TRANSFER_PROOF.md.
# Q interrupt samples and all board/ROM/RAM/SDRAM endpoints remain full rate.
set dec8_cpu_e_names {}
array unset dec8_cpu_e_counts
array set dec8_cpu_e_counts {}
set dec8_cpu_e_candidates [get_registers [list {emu|board|u_sys|u_main|CpuState*} {emu|board|u_sys|u_main|NextState*} {emu|board|u_sys|u_main|a*} {emu|board|u_sys|u_main|b*} {emu|board|u_sys|u_main|x*} {emu|board|u_sys|u_main|y*} {emu|board|u_sys|u_main|s*} {emu|board|u_sys|u_main|u*} {emu|board|u_sys|u_main|cc*} {emu|board|u_sys|u_main|dp*} {emu|board|u_sys|u_main|pc*} {emu|board|u_sys|u_main|tmp*} {emu|board|u_sys|u_main|addr*} {emu|board|u_sys|u_main|ea*} {emu|board|u_sys|u_main|InstPage2*} {emu|board|u_sys|u_main|InstPage3*} {emu|board|u_sys|u_main|Inst1*} {emu|board|u_sys|u_main|Inst2*} {emu|board|u_sys|u_main|Inst3*} {emu|board|u_sys|u_main|IntType*}]]
foreach_in_collection dec8_cpu_e_node $dec8_cpu_e_candidates {
  set dec8_cpu_e_native_name [get_node_info -name $dec8_cpu_e_node]
  set dec8_cpu_e_parts {}
  foreach dec8_cpu_e_part [split $dec8_cpu_e_native_name |] {lappend dec8_cpu_e_parts [lindex [split $dec8_cpu_e_part :] end]}
  set dec8_cpu_e_name [join $dec8_cpu_e_parts |]
  if {![regexp {emu\|board\|u_sys\|u_main\|(CpuState|NextState|a|b|x|y|s|u|cc|dp|pc|tmp|addr|ea|InstPage2|InstPage3|Inst1|Inst2|Inst3|IntType)(\[[0-9]+\]|\.(?:(?:CPUSTATE|INTTYPE)_[A-Z0-9_]+|[01]{1,7}))?$} $dec8_cpu_e_name -> dec8_cpu_e_field]} {error "Unreviewed CPU E endpoint $dec8_cpu_e_name"}
  if {![info exists dec8_cpu_e_counts($dec8_cpu_e_field)]} {set dec8_cpu_e_counts($dec8_cpu_e_field) 0}
  incr dec8_cpu_e_counts($dec8_cpu_e_field)
  lappend dec8_cpu_e_names $dec8_cpu_e_name
  puts "DEC8_CPU_E_NODE $dec8_cpu_e_name"
}
if {![info exists dec8_cpu_e_counts(CpuState)]} {error {Missing CPU E field u_main CpuState}}
if {$dec8_cpu_e_counts(CpuState) > 128} {error {Excess CPU E field u_main CpuState}}
if {![info exists dec8_cpu_e_counts(NextState)]} {error {Missing CPU E field u_main NextState}}
if {$dec8_cpu_e_counts(NextState) > 128} {error {Excess CPU E field u_main NextState}}
if {![info exists dec8_cpu_e_counts(a)]} {error {Missing CPU E field u_main a}}
if {$dec8_cpu_e_counts(a) > 8} {error {Excess CPU E field u_main a}}
if {![info exists dec8_cpu_e_counts(b)]} {error {Missing CPU E field u_main b}}
if {$dec8_cpu_e_counts(b) > 8} {error {Excess CPU E field u_main b}}
if {![info exists dec8_cpu_e_counts(x)]} {error {Missing CPU E field u_main x}}
if {$dec8_cpu_e_counts(x) > 16} {error {Excess CPU E field u_main x}}
if {![info exists dec8_cpu_e_counts(y)]} {error {Missing CPU E field u_main y}}
if {$dec8_cpu_e_counts(y) > 16} {error {Excess CPU E field u_main y}}
if {![info exists dec8_cpu_e_counts(s)]} {error {Missing CPU E field u_main s}}
if {$dec8_cpu_e_counts(s) > 16} {error {Excess CPU E field u_main s}}
if {![info exists dec8_cpu_e_counts(u)]} {error {Missing CPU E field u_main u}}
if {$dec8_cpu_e_counts(u) > 16} {error {Excess CPU E field u_main u}}
if {![info exists dec8_cpu_e_counts(cc)]} {error {Missing CPU E field u_main cc}}
if {$dec8_cpu_e_counts(cc) > 8} {error {Excess CPU E field u_main cc}}
if {![info exists dec8_cpu_e_counts(dp)]} {error {Missing CPU E field u_main dp}}
if {$dec8_cpu_e_counts(dp) > 8} {error {Excess CPU E field u_main dp}}
if {![info exists dec8_cpu_e_counts(pc)]} {error {Missing CPU E field u_main pc}}
if {$dec8_cpu_e_counts(pc) > 16} {error {Excess CPU E field u_main pc}}
if {![info exists dec8_cpu_e_counts(tmp)]} {error {Missing CPU E field u_main tmp}}
if {$dec8_cpu_e_counts(tmp) > 16} {error {Excess CPU E field u_main tmp}}
if {![info exists dec8_cpu_e_counts(addr)]} {error {Missing CPU E field u_main addr}}
if {$dec8_cpu_e_counts(addr) > 16} {error {Excess CPU E field u_main addr}}
if {![info exists dec8_cpu_e_counts(ea)]} {error {Missing CPU E field u_main ea}}
if {$dec8_cpu_e_counts(ea) > 16} {error {Excess CPU E field u_main ea}}
if {![info exists dec8_cpu_e_counts(InstPage2)]} {error {Missing CPU E field u_main InstPage2}}
if {$dec8_cpu_e_counts(InstPage2) > 1} {error {Excess CPU E field u_main InstPage2}}
if {![info exists dec8_cpu_e_counts(InstPage3)]} {error {Missing CPU E field u_main InstPage3}}
if {$dec8_cpu_e_counts(InstPage3) > 1} {error {Excess CPU E field u_main InstPage3}}
if {![info exists dec8_cpu_e_counts(Inst1)]} {error {Missing CPU E field u_main Inst1}}
if {$dec8_cpu_e_counts(Inst1) > 8} {error {Excess CPU E field u_main Inst1}}
if {![info exists dec8_cpu_e_counts(Inst2)]} {error {Missing CPU E field u_main Inst2}}
if {$dec8_cpu_e_counts(Inst2) > 8} {error {Excess CPU E field u_main Inst2}}
if {![info exists dec8_cpu_e_counts(Inst3)]} {error {Missing CPU E field u_main Inst3}}
if {$dec8_cpu_e_counts(Inst3) > 8} {error {Excess CPU E field u_main Inst3}}
if {![info exists dec8_cpu_e_counts(IntType)]} {error {Missing CPU E field u_main IntType}}
if {$dec8_cpu_e_counts(IntType) > 8} {error {Excess CPU E field u_main IntType}}
set dec8_cpu_e_domain [get_registers $dec8_cpu_e_names]
if {[get_collection_size $dec8_cpu_e_domain] != [llength $dec8_cpu_e_names]} {error {CPU E collection identity mismatch}}
puts "DEC8_CPU_E_DOMAIN u_main [get_collection_size $dec8_cpu_e_domain]"
set dec8_cpu_main_e_domain $dec8_cpu_e_domain
set_multicycle_path -setup -end 2 -from $dec8_cpu_e_domain -to $dec8_cpu_e_domain
set_multicycle_path -hold -end 1 -from $dec8_cpu_e_domain -to $dec8_cpu_e_domain
set dec8_cpu_e_names {}
array unset dec8_cpu_e_counts
array set dec8_cpu_e_counts {}
set dec8_cpu_e_candidates [get_registers [list {emu|board|u_sys|u_sub|CpuState*} {emu|board|u_sys|u_sub|NextState*} {emu|board|u_sys|u_sub|a*} {emu|board|u_sys|u_sub|b*} {emu|board|u_sys|u_sub|x*} {emu|board|u_sys|u_sub|y*} {emu|board|u_sys|u_sub|s*} {emu|board|u_sys|u_sub|u*} {emu|board|u_sys|u_sub|cc*} {emu|board|u_sys|u_sub|dp*} {emu|board|u_sys|u_sub|pc*} {emu|board|u_sys|u_sub|tmp*} {emu|board|u_sys|u_sub|addr*} {emu|board|u_sys|u_sub|ea*} {emu|board|u_sys|u_sub|InstPage2*} {emu|board|u_sys|u_sub|InstPage3*} {emu|board|u_sys|u_sub|Inst1*} {emu|board|u_sys|u_sub|Inst2*} {emu|board|u_sys|u_sub|Inst3*} {emu|board|u_sys|u_sub|IntType*}]]
foreach_in_collection dec8_cpu_e_node $dec8_cpu_e_candidates {
  set dec8_cpu_e_native_name [get_node_info -name $dec8_cpu_e_node]
  set dec8_cpu_e_parts {}
  foreach dec8_cpu_e_part [split $dec8_cpu_e_native_name |] {lappend dec8_cpu_e_parts [lindex [split $dec8_cpu_e_part :] end]}
  set dec8_cpu_e_name [join $dec8_cpu_e_parts |]
  if {![regexp {emu\|board\|u_sys\|u_sub\|(CpuState|NextState|a|b|x|y|s|u|cc|dp|pc|tmp|addr|ea|InstPage2|InstPage3|Inst1|Inst2|Inst3|IntType)(\[[0-9]+\]|\.(?:(?:CPUSTATE|INTTYPE)_[A-Z0-9_]+|[01]{1,7}))?$} $dec8_cpu_e_name -> dec8_cpu_e_field]} {error "Unreviewed CPU E endpoint $dec8_cpu_e_name"}
  if {![info exists dec8_cpu_e_counts($dec8_cpu_e_field)]} {set dec8_cpu_e_counts($dec8_cpu_e_field) 0}
  incr dec8_cpu_e_counts($dec8_cpu_e_field)
  lappend dec8_cpu_e_names $dec8_cpu_e_name
  puts "DEC8_CPU_E_NODE $dec8_cpu_e_name"
}
if {![info exists dec8_cpu_e_counts(CpuState)]} {error {Missing CPU E field u_sub CpuState}}
if {$dec8_cpu_e_counts(CpuState) > 128} {error {Excess CPU E field u_sub CpuState}}
if {![info exists dec8_cpu_e_counts(NextState)]} {error {Missing CPU E field u_sub NextState}}
if {$dec8_cpu_e_counts(NextState) > 128} {error {Excess CPU E field u_sub NextState}}
if {![info exists dec8_cpu_e_counts(a)]} {error {Missing CPU E field u_sub a}}
if {$dec8_cpu_e_counts(a) > 8} {error {Excess CPU E field u_sub a}}
if {![info exists dec8_cpu_e_counts(b)]} {error {Missing CPU E field u_sub b}}
if {$dec8_cpu_e_counts(b) > 8} {error {Excess CPU E field u_sub b}}
if {![info exists dec8_cpu_e_counts(x)]} {error {Missing CPU E field u_sub x}}
if {$dec8_cpu_e_counts(x) > 16} {error {Excess CPU E field u_sub x}}
if {![info exists dec8_cpu_e_counts(y)]} {error {Missing CPU E field u_sub y}}
if {$dec8_cpu_e_counts(y) > 16} {error {Excess CPU E field u_sub y}}
if {![info exists dec8_cpu_e_counts(s)]} {error {Missing CPU E field u_sub s}}
if {$dec8_cpu_e_counts(s) > 16} {error {Excess CPU E field u_sub s}}
if {![info exists dec8_cpu_e_counts(u)]} {error {Missing CPU E field u_sub u}}
if {$dec8_cpu_e_counts(u) > 16} {error {Excess CPU E field u_sub u}}
if {![info exists dec8_cpu_e_counts(cc)]} {error {Missing CPU E field u_sub cc}}
if {$dec8_cpu_e_counts(cc) > 8} {error {Excess CPU E field u_sub cc}}
if {![info exists dec8_cpu_e_counts(dp)]} {error {Missing CPU E field u_sub dp}}
if {$dec8_cpu_e_counts(dp) > 8} {error {Excess CPU E field u_sub dp}}
if {![info exists dec8_cpu_e_counts(pc)]} {error {Missing CPU E field u_sub pc}}
if {$dec8_cpu_e_counts(pc) > 16} {error {Excess CPU E field u_sub pc}}
if {![info exists dec8_cpu_e_counts(tmp)]} {error {Missing CPU E field u_sub tmp}}
if {$dec8_cpu_e_counts(tmp) > 16} {error {Excess CPU E field u_sub tmp}}
if {![info exists dec8_cpu_e_counts(addr)]} {error {Missing CPU E field u_sub addr}}
if {$dec8_cpu_e_counts(addr) > 16} {error {Excess CPU E field u_sub addr}}
if {![info exists dec8_cpu_e_counts(ea)]} {error {Missing CPU E field u_sub ea}}
if {$dec8_cpu_e_counts(ea) > 16} {error {Excess CPU E field u_sub ea}}
if {![info exists dec8_cpu_e_counts(InstPage2)]} {error {Missing CPU E field u_sub InstPage2}}
if {$dec8_cpu_e_counts(InstPage2) > 1} {error {Excess CPU E field u_sub InstPage2}}
if {![info exists dec8_cpu_e_counts(InstPage3)]} {error {Missing CPU E field u_sub InstPage3}}
if {$dec8_cpu_e_counts(InstPage3) > 1} {error {Excess CPU E field u_sub InstPage3}}
if {![info exists dec8_cpu_e_counts(Inst1)]} {error {Missing CPU E field u_sub Inst1}}
if {$dec8_cpu_e_counts(Inst1) > 8} {error {Excess CPU E field u_sub Inst1}}
if {![info exists dec8_cpu_e_counts(Inst2)]} {error {Missing CPU E field u_sub Inst2}}
if {$dec8_cpu_e_counts(Inst2) > 8} {error {Excess CPU E field u_sub Inst2}}
if {![info exists dec8_cpu_e_counts(Inst3)]} {error {Missing CPU E field u_sub Inst3}}
if {$dec8_cpu_e_counts(Inst3) > 8} {error {Excess CPU E field u_sub Inst3}}
if {![info exists dec8_cpu_e_counts(IntType)]} {error {Missing CPU E field u_sub IntType}}
if {$dec8_cpu_e_counts(IntType) > 8} {error {Excess CPU E field u_sub IntType}}
set dec8_cpu_e_domain [get_registers $dec8_cpu_e_names]
if {[get_collection_size $dec8_cpu_e_domain] != [llength $dec8_cpu_e_names]} {error {CPU E collection identity mismatch}}
puts "DEC8_CPU_E_DOMAIN u_sub [get_collection_size $dec8_cpu_e_domain]"
set dec8_cpu_sub_e_domain $dec8_cpu_e_domain
set_multicycle_path -setup -end 2 -from $dec8_cpu_e_domain -to $dec8_cpu_e_domain
set_multicycle_path -hold -end 1 -from $dec8_cpu_e_domain -to $dec8_cpu_e_domain
