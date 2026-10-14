# One queue lease covers all development stages. No assembler or RBF conversion.
package require ::quartus::project
package require ::quartus::flow
project_open Alpha68k_N -revision Alpha68k_N
foreach tool {map fit sta} {
    puts "ALPHA68KN_PREASSEMBLY_STAGE $tool"
    execute_module -tool $tool
}
project_close
