# Existing DB15 counter runs unconditionally at the 48MHz system clock.
# Bit3 is divide16, including reset/pause/ROM stalls; no RTL or exception change.
set ab_db15_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set ab_db15_counter [get_registers {*|jtframe_joymux:u_joymux|joy_db15:u_db15|JCLOCKS[3]}]
if {[get_collection_size $ab_db15_source] != 1 || [get_collection_size $ab_db15_counter] != 1} {
    error "AIRBLAST 48MHz DB15 clock source/target mismatch"
}
create_generated_clock -name ARBLST_DB15 -source $ab_db15_source -divide_by 16 $ab_db15_counter
derive_clock_uncertainty
