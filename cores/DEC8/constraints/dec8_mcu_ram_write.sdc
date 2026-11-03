# Conditional write capture only: normal writes use CE6; reset writes constant0.
# Exact8 RAM portA data endpoints; all address/write-enable/read/control checks remain1cycle.
if {![info exists dec8_mcu_ce_domain]} {error {Missing proved MCU CE domain}}
set dec8_mcu_ram_write_data [get_registers {emu|board|u_sys|u_mcu|ram_rtl_0|*porta_datain_reg*}]
if {[get_collection_size $dec8_mcu_ram_write_data] != 8} {error {Unexpected MCU RAM write-data geometry}}
foreach_in_collection node $dec8_mcu_ram_write_data {puts "DEC8_MCU_RAM_WRITE_NODE [get_node_info -name $node]"}
set_multicycle_path -setup -end 2 -from $dec8_mcu_ce_domain -to $dec8_mcu_ram_write_data
set_multicycle_path -hold -end 1 -from $dec8_mcu_ce_domain -to $dec8_mcu_ram_write_data
