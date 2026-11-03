# Async assertion/two receiving-edge release, actual wrapper proof20261024-03.
set mm_ram_reset_first [get_registers {*|ram1_reset_0}]
set mm_ram_reset_second [get_registers {*|ram1_reset_1}]
if {[get_collection_size $mm_ram_reset_first]!=1 || [get_collection_size $mm_ram_reset_second]!=1} {error "RAM1 reset synchronizer inventory changed"}
# The two asynchronous control pins are enumerated in madmotor_user_cdc.sdc.
# No D-path source exception: release/interstage/consumer paths stay timed.
