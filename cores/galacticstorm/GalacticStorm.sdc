derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# Anchor the forwarded DDR clock to RAM64's actual PLL output, so TimeQuest
# includes its physical source-to-pin path. A reference-clock frequency ratio
# alone makes this pin ideal and hides the external SDRAM read setup failure.
set gs_sd_source_names {}
foreach_in_collection gs_sd_pin [get_pins {*|core_clock|pll_i|*|divclk}] {
    if {[string first {general[0]} [get_pin_info -name $gs_sd_pin]]>=0} {
        lappend gs_sd_source_names [get_pin_info -name $gs_sd_pin]
    }
}
if {[llength $gs_sd_source_names]!=1} { error "RAM64 forwarded-clock source must resolve one PLL output name" }
# Resolve the iterator's pin name into a proper collection before checking
# cardinality and creating the clock; get_collection_size requires a collection.
set gs_sd_source [get_pins [lindex $gs_sd_source_names 0]]
if {[get_collection_size $gs_sd_source]!=1} { error "RAM64 forwarded-clock source must contain one PLL output pin" }
create_generated_clock -name SDRAMClkPin -source $gs_sd_source -divide_by 1 -invert [get_ports SDRAM_CLK]
# Generated clock periods are available after update_timing_netlist, not while
# read_sdc evaluates this file. The clock audit checks the propagated 64 MHz.
set sd_dq [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $sd_dq] != 16} { error "Physical SDRAM DQ query must contain16 pins" }
set sd_data [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS SDRAM_CKE}]
set_input_delay -clock SDRAMClkPin -max 7.4 $sd_dq
set_input_delay -clock SDRAMClkPin -min 2.5 $sd_dq
set_output_delay -clock SDRAMClkPin -max 2.5 $sd_data
set_output_delay -clock SDRAMClkPin -min -1.8 $sd_data

# sys/sys_top.sdc recognizes the Template's pll|pll_inst hierarchy. Our
# core_clock|pll_i hierarchy joins the same per-domain grouping instead of
# being compared with independent framework clocks. CPU, RAM and DSP aliases
# share one 64 MHz PLL output; keep that native clock and its inverted
# forwarded SDRAM clock together so no native or SDRAM setup/hold transfer is
# excluded by this grouping.
set gs_native_pll_clocks [get_clocks {*|core_clock|pll_i|*|divclk}]
if {[get_collection_size $gs_native_pll_clocks] != 1} {
    error "Galactic Storm common64 PLL query must contain one output clock"
}
set gs_native_clocks [get_clocks {*|core_clock|pll_i|*|divclk SDRAMClkPin}]
if {[get_collection_size $gs_native_clocks] != 2} {
    error "Galactic Storm native clock group must include SDRAMClkPin"
}
# These groups operate simultaneously on independent platform domains.
# Quartus17 times this identically to the legacy -exclusive spelling.
set_clock_groups -asynchronous \
    -group $gs_native_clocks \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# TG68K sequential state updates under clkena_in or its clkena_lw subset.
# The recovery gate proves minimum two-root-edge spacing through reset, pause,
# waits, bursts and restore. Exclude the root-edge mode selector and constant
# high flag bits; keep every other CPU/platform domain on its normal constraint.
set gs_cpu_state_all [get_registers -nowarn {*TG68KdotC_Kernel:cpu|* *TG68K_ALU:ALU|*}]
set gs_cpu_unenabled [get_registers -nowarn {*TG68KdotC_Kernel:cpu|use_VBR_Stackframe* *TG68K_ALU:ALU|Flags\[7\]* *TG68K_ALU:ALU|Flags\[6\]* *TG68K_ALU:ALU|Flags\[5\]*}]
set gs_cpu_ce_state [remove_from_collection $gs_cpu_state_all $gs_cpu_unenabled]
if {[get_collection_size $gs_cpu_state_all]<1 || [get_collection_size $gs_cpu_ce_state]<1} {
    error "Galactic Storm CPU CE multicycle state must resolve"
}
# Negative control: none of the identified every-edge register group may leak
# into the CE-qualified collection. Both exception commands use the same set.
set gs_cpu_unenabled_not_selected [remove_from_collection $gs_cpu_unenabled $gs_cpu_ce_state]
set gs_cpu_unenabled_leak [remove_from_collection $gs_cpu_unenabled $gs_cpu_unenabled_not_selected]
if {[get_collection_size $gs_cpu_unenabled_leak]!=0} {
    error "Unenabled CPU state leaked into the Galactic Storm MCE set"
}
puts "Galactic Storm CPU state registers: [get_collection_size $gs_cpu_state_all]"
puts "Galactic Storm CPU excluded every-edge registers: [get_collection_size $gs_cpu_unenabled]"
puts "Galactic Storm CPU CE MCE launch/capture registers: [get_collection_size $gs_cpu_ce_state]"
set_multicycle_path -setup -end -from $gs_cpu_ce_state -to $gs_cpu_ce_state 2
set_multicycle_path -hold -end -from $gs_cpu_ce_state -to $gs_cpu_ce_state 1

# A pending ROM miss is held on the CPU bus until the ROM cache presents its
# registered reply. The shared-memory/WRAM ACK is not selected during that
# interval. The simulation-only monitor in gs_main.sv checks the held request,
# address and ACK selection on every miss and its completion edge.
# gs_main_rom_cache (line cache) keeps the same held-miss protocol and monitor.
set gs_rom_pending [get_registers -nowarn {*gs_rom_cache:rom_cache|pending *gs_main_rom_cache:*rom_cache|pending}]
# The fitter may replicate the held-miss flag (pending~DUPLICATE). Every copy
# is the same logical register; require exactly one logical source and retime
# nothing: all physical copies launch the identical held request.
set gs_rom_pending_logical [dict create]
foreach_in_collection gs_rom_pending_reg $gs_rom_pending {
    dict set gs_rom_pending_logical [regsub {(~DUPLICATE)+$} [get_node_info -name $gs_rom_pending_reg] {}] 1
}
if {[dict size $gs_rom_pending_logical] != 1} {
    error "Galactic Storm main ROM pending source must resolve to exactly one logical register"
}
set_false_path -from $gs_rom_pending -to $gs_cpu_ce_state
puts "Galactic Storm held ROM pending sources: [get_collection_size $gs_rom_pending]"
puts "Galactic Storm held ROM false-path CPU captures: [get_collection_size $gs_cpu_ce_state]"

# Preserve scoped native held-bank protocol bounds in the real wrapper.
proc gs_held_bank {source_names destination_names bound} {
    set launch [get_registers -nowarn $source_names]
    set capture [get_registers -nowarn $destination_names]
    if {[get_collection_size $launch]==0 || [get_collection_size $capture]==0} {
        error "Galactic Storm held-bank query is empty"
    }
    set_max_delay $bound -from $launch -to $capture
    set_false_path -hold -from $launch -to $capture
}
gs_held_bank {*|captured_scp*} {*gs_video_gpu:video|gs_gpu_rotate:gpu|saved_controls*} 31.25
gs_held_bank {*|captured_scn*} {*gs_video_gpu:video|gs_gpu_rotate:gpu|saved_scn*} 31.25
gs_held_bank {*|captured_affine*} {*gs_video_gpu:video|gs_gpu_rotate:gpu|rotation_x* *gs_video_gpu:video|gs_gpu_rotate:gpu|rotation_y* *gs_video_gpu:video|gs_gpu_rotate:gpu|rotation_regs*} 31.25
gs_held_bank {*gs_bus_cdc:host_bridge|packet*} {*gs_bus_cdc:host_bridge|ram_write* *gs_bus_cdc:host_bridge|ram_addr* *gs_bus_cdc:host_bridge|ram_wdata* *gs_bus_cdc:host_bridge|ram_bytes*} 20.833
# Common64: two receiver intervals are 31.25 ns; do not retain the CPU32 bound.
gs_held_bank {*gs_bus_cdc:host_bridge|reply*} {*gs_bus_cdc:host_bridge|cpu_rdata*} 31.25

# The ROM/reset gates assert these preserved reset synchronizers asynchronously.
# Release propagates through two stages in each receiving clock domain. Exclude
# only raw reset-source paths ending in those stages; stage-to-stage and normal
# payload/datapath timing remain constrained.
# ready includes EEPROM loading; HPS cfg[1]/status[0] are the two warm-reset
# controls in gs_mister. Physical synthesis can duplicate these source registers.
# Their asynchronous assertion/deassertion enters only release synchronizers.
set gs_hps_button_reset [get_registers -nowarn {*hps_io:hps_io|cfg[1]}]
set gs_hps_status_reset [get_registers -nowarn {*hps_io:hps_io|status[0]}]
set gs_eeprom_reset_source [get_registers -nowarn {*gs_download:loader|eeprom_loaded*}]
if {[get_collection_size $gs_hps_button_reset]<1 || [get_collection_size $gs_hps_status_reset]<1 || [get_collection_size $gs_eeprom_reset_source]<1} {
    error "Raw warm-reset and EEPROM-ready sources must resolve, including fitted duplicates"
}
set gs_reset_sources [get_registers -nowarn {*gs_download:loader|bad* *gs_download:loader|rom_loaded* *gs_download:loader|eeprom_loaded* *hps_io:hps_io|cfg[1] *hps_io:hps_io|status[0] *|cold_release*}]
set gs_ddr_reset_release [get_registers -nowarn {*gs_ddr_cdc:bridge|client_reset_s* *gs_ddr_cdc:bridge|ram_reset_s*}]
if {[get_collection_size $gs_ddr_reset_release]!=4} {
    error "DDR reset release must resolve four preserved domain-local stage registers"
}
set gs_reset_release [get_registers -nowarn {*gs_bus_cdc:*|cpu_reset_s* *gs_bus_cdc:*|ram_reset_s* *gs_audio_engine:engine|dsp_reset_s* *gs_audio_engine:engine|dsp_cold_s* *gs_ddr_cdc:bridge|client_reset_s* *gs_ddr_cdc:bridge|ram_reset_s*}]
if {[get_collection_size $gs_reset_sources]==0 || [get_collection_size $gs_reset_release]<16} {
    error "Native asynchronous reset queries must resolve sources and at least sixteen release-stage registers"
}
set_false_path -from $gs_reset_sources -to $gs_reset_release

# The falling-edge input capture must reach its next rising-edge retimer.
# Keep the real half-cycle/hold checks; these maximum delays tighten setup
# solely to steer placement away from the measured long routed wires.
proc gs_dq_bank {stem allow_copies} {
    set bank [get_registers -nowarn [format {*sdram:controller|%s*} $stem]]
    set count [get_collection_size $bank]
    if {$count<16 || (!$allow_copies && $count!=16)} {
        error "Galactic Storm $stem must contain all sixteen capture bits"
    }
    set base_bits {}
    set pattern [format {(^|[|])%s\[([0-9]+)\](~DUPLICATE[0-9_]*)?$} $stem]
    foreach_in_collection node $bank {
        set name [get_register_info -name $node]
        if {![regexp $pattern $name -> separator bit duplicate] || $bit<0 || $bit>15} {
            error "Unexpected Galactic Storm capture endpoint: $name"
        }
        if {$duplicate eq {}} {lappend base_bits $bit}
    }
    if {[llength [lsort -integer -unique $base_bits]]!=16} {
        error "Galactic Storm $stem base-bit coverage is incomplete"
    }
    return $bank
}
set gs_dq_capture [gs_dq_bank dq_reg 0]
set gs_dq_retime [gs_dq_bank dq_pos 1]
set_max_delay 6.0 -from $gs_dq_capture -to $gs_dq_retime

# Common64 same-root audio reset-request capture. The 4.5 ns maximum is a
# placement target carried forward for measurement; it cuts no path and must
# be judged against the new common-clock fitted report.
set gs_ram_clock_names {}
foreach_in_collection gs_clock $gs_native_pll_clocks {
    if {[string first {general[0]} [get_clock_info -name $gs_clock]]>=0} {
        lappend gs_ram_clock_names [get_clock_info -name $gs_clock]
    }
}
if {[llength $gs_ram_clock_names]!=1} {error "Expected one RAM64 clock for reset guidance"}
set gs_ram_clock [get_clocks [lindex $gs_ram_clock_names 0]]
set gs_dsp_reset_capture [get_registers -nowarn {*gs_audio_engine:engine|dsp_reset_request}]
if {[get_collection_size $gs_dsp_reset_capture]!=1} {error "Expected one DSP reset-request capture"}
set_max_delay 4.5 -from $gs_ram_clock -to $gs_dsp_reset_capture
