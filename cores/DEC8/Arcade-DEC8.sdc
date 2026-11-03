# Conservative common48 characterization: no core CE or DIP exceptions.
derive_pll_clocks
derive_clock_uncertainty

source constraints/dec8_mcu_ce.sdc

source constraints/dec8_cpu_e.sdc

source constraints/dec8_mcu_ram_write.sdc
source constraints/dec8_cpu_sprite_snapshot.sdc
