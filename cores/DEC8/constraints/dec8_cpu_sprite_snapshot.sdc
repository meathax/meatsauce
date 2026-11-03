# Only CPU-dependent synchronous clear of copied mask: main slot6 min7, sub slot10 min4.
# Reset clear constant0 and autonomous E_DECIDE copies independent of current CPU data.
if {![info exists dec8_cpu_main_e_domain] || ![info exists dec8_cpu_sub_e_domain]} {error {Missing proved CPU E domains}}
set dec8_sprite_copied_mask [get_registers {emu|board|u_sys|u_video|u_spr|g_snap.copied*}]
if {[get_collection_size $dec8_sprite_copied_mask] != 1024} {error {Unexpected sprite copied-mask geometry}}
puts "DEC8_SPRITE_COPIED_MASK_COUNT [get_collection_size $dec8_sprite_copied_mask]"
set_multicycle_path -setup -end 2 -from $dec8_cpu_main_e_domain -to $dec8_sprite_copied_mask
set_multicycle_path -hold -end 1 -from $dec8_cpu_main_e_domain -to $dec8_sprite_copied_mask
set_multicycle_path -setup -end 2 -from $dec8_cpu_sub_e_domain -to $dec8_sprite_copied_mask
set_multicycle_path -hold -end 1 -from $dec8_cpu_sub_e_domain -to $dec8_sprite_copied_mask
