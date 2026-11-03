# Source-bound two-flop reset and held-word audio crossing. No clock changes.
proc snk68_regs {pattern count} {
 set x [get_registers $pattern]
 if {[get_collection_size $x] != $count} {error "SNK68 CDC inventory: $pattern expected $count"}
 return $x
}
set snk68_src_clock [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set snk68_dst_clock [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $snk68_src_clock]!=1 || [get_collection_size $snk68_dst_clock]!=1} {error "SNK68 CDC clock inventory"}
set snk68_ts [get_clock_info -period $snk68_src_clock]
set snk68_td [get_clock_info -period $snk68_dst_clock]
if {abs($snk68_ts-13.888)>0.002 || abs($snk68_td-40.682)>0.02} {error "SNK68 CDC clock profile changed"}
# Request crosses two destination stages; capture is a further destination edge.
# Held payload cannot change until ACK crosses two source stages and is observed.
# Budget one Tdst of arrival and one Tsrc of replacement skew; interstage paths
# and source capture remain full-rate timed. Validate every physical bus bit.
set snk68_held [snk68_regs {*audio_transfer|held_payload[*]} 32]
set snk68_received [snk68_regs {*audio_transfer|dst_left[*] *audio_transfer|dst_right[*]} 32]
set_max_delay -from $snk68_held -to $snk68_received $snk68_td
set_min_delay -from $snk68_held -to $snk68_received [expr {-$snk68_ts}]
set_false_path -from [snk68_regs {*audio_transfer|request_toggle} 1] -to [snk68_regs {*audio_transfer|request_sync[0]} 1]
set_false_path -from [snk68_regs {*audio_transfer|acknowledge_toggle} 1] -to [snk68_regs {*audio_transfer|acknowledge_sync[0]} 1]
# Asynchronous assertion only: exact dedicated reset synchronizer clear pins.
# No D pins, interstage data, released reset output or consumers are cut.
set snk68_reset_clear [get_pins -compatibility_mode {
 *|game_reset_sys|release_pipe[*]|clrn
 *|game_reset_cpu|release_pipe[*]|clrn
 *|game_reset_opl|release_pipe[*]|clrn
 *|sdram_reset_release|release_pipe[*]|clrn
 audio_transfer|source_reset|release_pipe[*]|clrn
 audio_transfer|destination_reset|release_pipe[*]|clrn
 framework_audio_reset|release_pipe[*]|clrn
}]
if {[get_collection_size $snk68_reset_clear]!=14} {error "SNK68 reset clear-pin inventory"}
set_false_path -to $snk68_reset_clear

# Preserve the original framework core/audio clock-pair exclusions only through
# unchanged platform pins. D pins alone omit register CE/load controls; keeper
# objects do not match every through point in Quartus17. The all-pin difference
# was natively checked: every one of32 held-audio setup/hold paths remains timed.
# This is a subset of the original clock-pair cut, never a new clock exclusion.
# Native qualification must again enumerate32 payload paths and both sync stages.
set snk68_all_pins [get_pins -compatibility_mode {*}]
set snk68_new_audio_pins [get_pins -compatibility_mode {*audio_transfer|*}]
if {[get_collection_size $snk68_new_audio_pins]<100} {error "SNK68 new bridge pin inventory missing"}
set snk68_old_platform_pins [remove_from_collection $snk68_all_pins $snk68_new_audio_pins]
set_false_path -from $snk68_src_clock -to $snk68_dst_clock -through $snk68_old_platform_pins
set_false_path -from $snk68_dst_clock -to $snk68_src_clock -through $snk68_old_platform_pins
