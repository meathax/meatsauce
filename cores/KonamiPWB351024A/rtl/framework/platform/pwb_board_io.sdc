# Owned board interface constraints; stock sys/ remains unchanged.
# sys_top.v launches the 27 video signals on hdmi_tx_clk rising edges and
# hdmiclk_ddr forwards h=0/l=1: receiver rising edge is the internal falling edge.
# ADV7513 Rev B: tVSU=1.8 ns, tVHLD=1.3 ns. Project allowance for differential
# PCB flight/skew is +/-0.5 ns, not a measured board characterization.
# Contract: Main configures zero additional ADV7513 input-clock delay (0xBA=0x60).
# Do not reuse an SDRAM phase or an unqualified donor multicycle exception here.
proc pwb_io_clock_named {name} {
    set found {}
    foreach_in_collection clock [get_clocks *] {
        if {[get_clock_info -name $clock] eq $name} {lappend found $clock}
    }
    if {[llength $found] != 1} {error "PWB board I/O clock missing/ambiguous: $name"}
    return [lindex $found 0]
}
set pwb_hdmi_forward_pin [get_pins -compatibility_mode {*hdmiclk_ddr|*|muxsel}]
if {[get_collection_size $pwb_hdmi_forward_pin] != 1} {
    error "PWB HDMI forwarding DDIO clock must resolve to one fitted pin"
}
set pwb_hdmi_video_ports [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $pwb_hdmi_video_ports] != 27} {
    error "PWB HDMI contract must cover all 27 video output signals"
}
set pwb_hdmi_native_master [pwb_io_clock_named {emu|u_clock|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set pwb_hdmi_scaler_master [pwb_io_clock_named {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
foreach pair [list [list native $pwb_hdmi_native_master] [list scaler $pwb_hdmi_scaler_master]] {
    lassign $pair mode master
    set name pwb_hdmi_${mode}_forward
    create_generated_clock -name $name -source $pwb_hdmi_forward_pin \
        -master_clock $master -divide_by 1 -invert -add [get_ports HDMI_TX_CLK]
    set_output_delay -clock [get_clocks $name] -max 2.3 -add_delay $pwb_hdmi_video_ports
    set_output_delay -clock [get_clocks $name] -min -1.8 -add_delay $pwb_hdmi_video_ports
}
# The two selected hdmi_tx_clk sources are mutually exclusive operating modes.
# Keep the original source clocks and their downstream generated clocks together;
# the existing platform asynchronous groups remain authoritative for other clocks.
set pwb_hdmi_native_group [get_clocks [list [get_clock_info -name $pwb_hdmi_native_master] pwb_hdmi_native_forward]]
set pwb_hdmi_scaler_group [get_clocks [list [get_clock_info -name $pwb_hdmi_scaler_master] pwb_hdmi_scaler_forward]]
if {[get_collection_size $pwb_hdmi_native_group] != 2 || [get_collection_size $pwb_hdmi_scaler_group] != 2} {
    error "PWB HDMI mode groups must contain each actual parent and its forwarded child"
}
set_clock_groups -physically_exclusive \
    -group $pwb_hdmi_native_group \
    -group $pwb_hdmi_scaler_group
puts "PWB board I/O: 27 HDMI video outputs, both physical forwarded-clock modes"

# Separate physical transport bounds for valid I2S streaming. Q17 does not
# implement set_max_delay -datapath_only. These supported constraints are not
# interpreted as standalone datapath proof: the mandatory four-corner producer
# and consumer measure physical cell/net/pad arcs and launch-clock insertion.
# No global multicycle exception is applied. Reset/config transitions are not
# valid audio samples; see the source-bound audio-io-contract.json.
set pwb_audio_io_roles {
    {data  *audio_out*|i2s*|sdata HDMI_I2S}
    {frame *audio_out*|i2s*|lrclk HDMI_LRCLK}
    {clock *audio_out*|i2s*|sclk  HDMI_SCLK}
}
foreach role $pwb_audio_io_roles {
    lassign $role id pattern pad
    set source [get_registers $pattern]
    set terminal [get_ports $pad]
    if {[get_collection_size $source] != 1 || [get_collection_size $terminal] != 1} {
        error "PWB I2S $id physical transport must resolve to one source and one pad"
    }
    # Native max_delay includes launch-clock latency. The independent physical
    # cell/net/pad bound remains 20 ns; 30 ns is the total-arrival constraint.
    set_max_delay -from $source -to $terminal 30.0
    set_min_delay -from $source -to $terminal 0.0
}
puts "PWB board I/O: three I2S physical transport bounds; independent streaming margin gate required"

# MCLK is a direct PLL clock export, not a data signal. Retain the actual PLL
# relationship and physical output path rather than assigning an output delay.
set pwb_audio_master [pwb_io_clock_named {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set pwb_audio_mclk_pin [get_pins -compatibility_mode {*pll_audio*|divclk}]
if {[get_collection_size $pwb_audio_mclk_pin] != 1 || [get_collection_size [get_ports HDMI_MCLK]] != 1} {
    error "PWB audio MCLK export must resolve to one actual PLL pin and one pad"
}
foreach_in_collection pin $pwb_audio_mclk_pin {
    if {[get_pin_info -name $pin] ne [get_clock_info -name $pwb_audio_master]} {
        error "PWB audio MCLK pin must be the actual named PLL output clock target"
    }
}
set pwb_audio_master_period [get_clock_info -period $pwb_audio_master]
if {$pwb_audio_master_period < 40.0 || $pwb_audio_master_period > 41.0} {
    error "PWB audio master is outside the bound 24.576 MHz nominal source family"
}
create_generated_clock -name pwb_audio_mclk_forward -source $pwb_audio_mclk_pin \
    -master_clock $pwb_audio_master -divide_by 1 [get_ports HDMI_MCLK]
puts "PWB audio MCLK: actual master period $pwb_audio_master_period ns, no inversion"

# MCP23009 source outputs are low/Z. Native hardware may implement constant-zero
# data with dynamic OE, or an equivalent dedicated open-drain primitive. These
# are output-control transports, not a guessed physical pin topology. Actual
# primitive configuration, normalized drive-low function and complete role
# inventories are checked by the mandatory native physical/protocol consumer.
set pwb_mcp_io_roles {
    {clock *mcp23009*|i2c*|I2C_CLOCK I2C_CLOCK IO_SCL}
    {mode  *mcp23009*|i2c*|SCLK SCLK IO_SCL}
    {data  *mcp23009*|i2c*|SDO?3? {SDO[3]} IO_SDA}
}
foreach role $pwb_mcp_io_roles {
    lassign $role id pattern leaf pad
    set source [get_registers $pattern]
    set terminal [get_ports $pad]
    if {[get_collection_size $source] != 1 || [get_collection_size $terminal] != 1} {
        error "PWB MCP $id OE transport must resolve to exactly one source and pad"
    }
    foreach_in_collection node $source {
        if {[lindex [split [get_register_info -name $node] |] end] ne $leaf} {
            error "PWB MCP $id OE source has an unproved fitted alias"
        }
    }
    set_max_delay -from $source -to $terminal 30.0
    set_min_delay -from $source -to $terminal 0.0
}
set pwb_mcp_input_registers [get_registers {*mcp23009*|i2c*|ACK *mcp23009*|i2c*|rdata*}]
set pwb_mcp_expected_input_leaves {ACK {rdata[0]} {rdata[1]} {rdata[2]} {rdata[3]} {rdata[4]}}
if {[get_collection_size $pwb_mcp_input_registers] != 6 || [get_collection_size [get_ports IO_SDA]] != 1} {
    error "PWB MCP input contract requires the ACK and five used read-bit endpoints"
}
set pwb_mcp_seen_input_leaves {}
foreach_in_collection node $pwb_mcp_input_registers {
    set leaf [lindex [split [get_register_info -name $node] |] end]
    if {[lsearch -exact $pwb_mcp_expected_input_leaves $leaf] < 0 ||
        [lsearch -exact $pwb_mcp_seen_input_leaves $leaf] >= 0} {
        error "PWB MCP input contains an unproved alias or duplicate receiver"
    }
    lappend pwb_mcp_seen_input_leaves $leaf
}
# Incoming SDA is externally clocked by the emitted I2C protocol. This is a
# bounded transport request, not a claim of periodic 50 MHz SDA launch timing.
# Do not add a fabricated source clock or an artificial per-fabric-edge hold.
set_max_delay -from [get_ports IO_SDA] -to $pwb_mcp_input_registers 30.0
# Clockless input hold remains an exact reviewed boundary until the separately
# collected min-route/primitive-aperture evidence passes the real CE/protocol
# hold theorem. Inspection-only constraints must not alter production reports.
puts "PWB MCP I/O: three OE transports and six input endpoints; protocol gate required"
