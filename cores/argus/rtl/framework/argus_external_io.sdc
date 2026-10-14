# Argus-owned external interface constraints. Load AFTER derive_pll_clocks and
# the generated argus_sys_top.sdc. Source/enable authority is in io-contract.json.
# These are pin timing contracts, not timing acceptance of any previous fit.
proc argus_io_one {kind pattern expected} {
    set c [$kind $pattern]
    if {[get_collection_size $c] != $expected} {
        error "Argus external IO: $kind $pattern expected $expected objects"
    }
    return $c
}
proc argus_io_clock_target {c} {
    set t [get_clock_info -targets $c]
    if {[get_collection_size $t] != 1} {error "Argus external IO: clock source cardinality"}
    return $t
}
set argus_io_game [argus_io_one get_clocks {*|game_pll|pll_inst|altera_pll_i|*|divclk} 2]
set argus_io_game0 {}
set argus_io_game1 {}
set argus_io_game_names {}
foreach_in_collection c $argus_io_game {
    set n [get_clock_info -name $c]
    lappend argus_io_game_names $n
    if {[regexp {general\[0\]\.gpll~PLL_OUTPUT_COUNTER\|divclk$} $n]} {set argus_io_game0 $c}
    if {[regexp {general\[1\]\.gpll~PLL_OUTPUT_COUNTER\|divclk$} $n]} {set argus_io_game1 $c}
}
if {$argus_io_game0 eq {} || $argus_io_game1 eq {}} {error "Argus external IO: game PLL output identity"}
if {abs([get_clock_info -period $argus_io_game0] - 18.5185185) > 0.002} {error "Argus external IO: game master period"}
if {abs([get_clock_info -period $argus_io_game1] - 18.5185185) > 0.002} {error "Argus external IO: SDRAM master period"}
set argus_io_hdmi [argus_io_one get_clocks {*pll_hdmi*|*divclk} 1]
set argus_io_audio [argus_io_one get_clocks {*pll_audio*|*divclk} 1]
set argus_io_fpga2 [argus_io_one get_clocks {FPGA_CLK2_50} 1]
if {abs([get_clock_info -period $argus_io_fpga2] - 20.0) > 0.001} {error "Argus external IO: MCP master period"}
# The selected fixed fractional PLL has no runtime reconfiguration port.
# Quartus 17 derives 40.682 ns; 48/96 kHz selection changes CE only.
set argus_io_audio_period [get_clock_info -period $argus_io_audio]
if {abs($argus_io_audio_period - 40.682) > 0.002} {error "Argus external IO: audio master period $argus_io_audio_period ns; expected fixed native 40.682 ns"}

# SDRAM_CLK is out1 itself, +180 degrees to out0. Do not add another phase.
create_generated_clock -name argus_sdram_pad -source [argus_io_clock_target $argus_io_game1] -master_clock [get_clock_info -name $argus_io_game1] -divide_by 1 [argus_io_one get_ports {SDRAM_CLK} 1]
set argus_io_dq [argus_io_one get_ports {SDRAM_DQ[*]} 16]
set argus_io_sdram_out [argus_io_one get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE} 38]
set_input_delay -clock argus_sdram_pad -max 9.5 $argus_io_dq
set_input_delay -clock argus_sdram_pad -min 0.0 $argus_io_dq
set_output_delay -clock argus_sdram_pad -max 2.5 $argus_io_sdram_out
set_output_delay -clock argus_sdram_pad -min -1.8 $argus_io_sdram_out

# HDMI SDR data changes on the selected master rising edge. altddio_out drives
# datain_h=0/datain_l=1, hence ADV7513's active rising pad edge is the falling
# master edge. Define BOTH actual runtime mux sources; no invented HDMI phase.
create_generated_clock -name argus_hdmi_scaled_pad -source [argus_io_clock_target $argus_io_hdmi] -master_clock [get_clock_info -name $argus_io_hdmi] -divide_by 1 -invert [argus_io_one get_ports {HDMI_TX_CLK} 1]
create_generated_clock -name argus_hdmi_direct_pad -source [argus_io_clock_target $argus_io_game0] -master_clock [get_clock_info -name $argus_io_game0] -divide_by 1 -invert -add [argus_io_one get_ports {HDMI_TX_CLK} 1]
set argus_io_video [argus_io_one get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS} 27]
foreach pad {argus_hdmi_scaled_pad argus_hdmi_direct_pad} {
    set_output_delay -clock $pad -max 2.55 -add_delay $argus_io_video
    set_output_delay -clock $pad -min -2.05 -add_delay $argus_io_video
}

# Audio MCLK is directly forwarded. I2S mode changes 48/96 kHz at runtime, and
# its reset divider phase is not a declared clock phase: constrain actual
# register-to-pad propagation rather than inventing a fixed BCLK waveform.
create_generated_clock -name argus_audio_mclk_pad -source [argus_io_clock_target $argus_io_audio] -master_clock [get_clock_info -name $argus_io_audio] -divide_by 1 [argus_io_one get_ports {HDMI_MCLK} 1]
set argus_io_i2s [argus_io_one get_ports {HDMI_SCLK HDMI_LRCLK HDMI_I2S USER_IO[2] USER_IO[4] USER_IO[5]} 6]
set_max_delay 20.0 -to $argus_io_i2s
set_min_delay 0.0 -to $argus_io_i2s

# MCP23009: source instantiates i2c #(50_000_000,250_000), exactly 200 master
# cycles/SCL period. SCL is a clock-enable protocol; there is no new RTL clock.
# BEGIN exact MCP divider and physical pad source
proc argus_io_mcp_toggle_keepers {} {
    # Native get_registers includes physical copies of this exact logical keeper.
    set rs [get_registers {*mcp23009*|*i2c*|I2C_CLOCK}]
    set count [get_collection_size $rs]
    if {$count < 1 || $count > 2} {error "Argus external IO: MCP toggle keeper cardinality"}
    set names {}
    foreach_in_collection r $rs {
        set n [get_register_info -name $r]
        if {![regexp {^argus_mcp23009:mcp23009\|i2c:i2c\|I2C_CLOCK(~DUPLICATE)?$} $n]} {error "Argus external IO: unexpected MCP toggle keeper $n"}
        lappend names $n
    }
    if {[llength [lsort -unique $names]] != $count || [lsearch -exact $names {argus_mcp23009:mcp23009|i2c:i2c|I2C_CLOCK}] < 0} {error "Argus external IO: MCP toggle keeper identities"}
    return $rs
}
proc argus_io_mcp_pad_source {scl} {
    # SCL is gated with SCLK; use the actual data fanin keeper, not a guessed copy.
    # -synch follows data edges; it excludes the register clock/reset fanin cones.
    set sources {}
    foreach_in_collection n [get_fanins -synch $scl] {
        set name [get_node_info -name $n]
        if {[regexp {^argus_mcp23009:mcp23009\|i2c:i2c\|I2C_CLOCK(~DUPLICATE)?$} $name]} {lappend sources $name}
    }
    if {[llength $sources] != 1} {error "Argus external IO: MCP SCL physical divider source cardinality: $sources"}
    set compatibility [string map [list {argus_mcp23009:} {} {i2c:} {}] [lindex $sources 0]]
    append compatibility {|q}
    set pin [get_pins -compatibility_mode [list $compatibility]]
    if {[get_collection_size $pin] != 1 || [get_pin_info -name $pin] ne $compatibility} {error "Argus external IO: exact MCP SCL divider Q pin $compatibility"}
    return $pin
}
set argus_io_mcp_toggles [argus_io_mcp_toggle_keepers]
create_generated_clock -name argus_mcp_toggle -source [argus_io_one get_ports {FPGA_CLK2_50} 1] -master_clock [get_clock_info -name $argus_io_fpga2] -divide_by 200 -phase 180 $argus_io_mcp_toggles
set argus_io_mcp_scl [argus_io_one get_ports {IO_SCL} 1]
set argus_io_mcp_source [argus_io_mcp_pad_source $argus_io_mcp_scl]
# Division and phase belong to the real register output; the pad only forwards it.
create_generated_clock -name argus_mcp_scl_pad -source $argus_io_mcp_source -master_clock argus_mcp_toggle -divide_by 1 $argus_io_mcp_scl
# END exact MCP divider and physical pad source
proc argus_io_mcp_receivers {logical_names} {
    # Preserve every fitted copy of the six source-proven SDA receiver keepers.
    # Native logical-name queries include ~DUPLICATE; cardinality is physical.
    set actual_names {}
    set by_logical [dict create]
    foreach_in_collection r [get_registers {*mcp23009*|*i2c*|*}] {
        set n [get_register_info -name $r]
        if {![regexp {\|(ACK|rdata\[[0-7]\])(.*)$} $n unused leaf suffix]} {continue}
        set logical [string range $n 0 [expr {[string length $n]-[string length $suffix]-1}]]
        if {[lsearch -exact $logical_names $logical] < 0 || $suffix ni {{} ~DUPLICATE}} {
            error "Argus MCP unknown SDA receiver lineage: $n"
        }
        dict lappend by_logical $logical $n
        lappend actual_names $n
    }
    if {[llength [lsort -unique $actual_names]] != [llength $actual_names]} {error "Argus MCP duplicate physical receiver identity"}
    foreach logical $logical_names {
        if {![dict exists $by_logical $logical]} {error "Argus MCP missing logical receiver: $logical"}
        set physical [dict get $by_logical $logical]
        if {[llength $physical] > 2 || [lsearch -exact $physical $logical] < 0} {
            error "Argus MCP original/copy receiver coverage: $logical $physical"
        }
    }
    set receivers [get_registers $logical_names]
    set queried_names {}
    foreach_in_collection r $receivers {lappend queried_names [get_register_info -name $r]}
    if {[lsort $queried_names] ne [lsort $actual_names]} {error "Argus MCP complete physical receiver collection mismatch"}
    return [list $receivers $by_logical]
}
set argus_io_mcp_expected_names [list {argus_mcp23009:mcp23009|i2c:i2c|ACK} {argus_mcp23009:mcp23009|i2c:i2c|rdata[0]} {argus_mcp23009:mcp23009|i2c:i2c|rdata[1]} {argus_mcp23009:mcp23009|i2c:i2c|rdata[2]} {argus_mcp23009:mcp23009|i2c:i2c|rdata[3]} {argus_mcp23009:mcp23009|i2c:i2c|rdata[4]}]
lassign [argus_io_mcp_receivers $argus_io_mcp_expected_names] argus_io_mcp_receivers argus_io_mcp_receiver_groups
set argus_io_sda [argus_io_one get_ports {IO_SDA} 1]
# Worst data-valid delay .9us + 1ns SCL flight + 1ns SDA flight. The -20ns
# minimum is conservative for the hold mapping, not an alleged negative flight.
set_input_delay -clock argus_mcp_scl_pad -clock_fall -max 902.0 $argus_io_sda
set_input_delay -clock argus_mcp_scl_pad -clock_fall -min -20.0 $argus_io_sda
# Setup: first next CLK2 edge (+20ns) + 100 further cycles = actual +2020ns
# enabled sample. Hold: next SCL fall (+4000ns), with the extra -20ns allowance,
# gives the same 1980ns ideal margin as the real +2020ns sample. Exact receivers.
set_multicycle_path -setup -end 101 -from $argus_io_sda -to $argus_io_mcp_receivers
set_multicycle_path -hold -start 1 -from $argus_io_sda -to $argus_io_mcp_receivers
set argus_io_mcp_out [argus_io_one get_ports {IO_SCL IO_SDA} 2]
set_max_delay 100.0 -to $argus_io_mcp_out
set_min_delay 0.0 -to $argus_io_mcp_out

# Extend the EXISTING reviewed groups to include their actual forwarded pads.
# This retains game<->framework CDC intent while keeping every external pad
# related to its real data master. No game/out1 or game/SDRAM cut is introduced.
set_clock_groups -exclusive \
    -group [get_clocks [concat $argus_io_game_names {argus_sdram_pad argus_hdmi_direct_pad}]] \
    -group [get_clocks [list [get_clock_info -name $argus_io_hdmi] argus_hdmi_scaled_pad]] \
    -group [get_clocks [list [get_clock_info -name $argus_io_audio] argus_audio_mclk_pad]] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [argus_io_one get_clocks {*|h2f_user0_clk} 1] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50 argus_mcp_toggle argus_mcp_scl_pad}] \
    -group [get_clocks {FPGA_CLK3_50}]

# HPS owns HDMI configuration I2C and the asynchronous HDMI interrupt. Their
# complete source cones terminate in hard-IP pins; there is no fabric sampler.
set_false_path -from [argus_io_one get_ports {HDMI_I2C_SCL HDMI_I2C_SDA HDMI_TX_INT} 3]
set_false_path -to [argus_io_one get_ports {HDMI_I2C_SCL HDMI_I2C_SDA} 2]
# Exact non-clocked indicators / inactive card or analog/self-clocked outputs.
set_false_path -to [argus_io_one get_ports {LED[0] LED[2] LED[6]} 3]
set_false_path -to [argus_io_one get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[0] SDIO_DAT[1] SDIO_DAT[2] SDIO_DAT[3] SD_SPI_CS SDCD_SPDIF} 8]
