# Integrated divider-source constraints; full physical timing remains pending.
# Same physical assumptions/min/max/exception scope as frozen base.
# Root must verify mapped register clocks, source latency and OE paths.
# SW1 is a USER audio/static-route selector, not a periodic clock. This
# candidate does not invent its waveform or assert a physical switch mode.
# REVIEW CANDIDATE ONLY. Source after sys_top.sdc/Penguin.sdc/derive_pll_clocks.
# Recovery/assumptions: evidence/native/platform-io-candidate.json.
# No clock creation at a forwarded-clock port treats that port as data.
# No CE multicycles, fabricated synchronizers, or global I/O false paths.

proc penguin_io_one_register {pattern {max_live 1}} {
    set originals [get_registers -no_duplicates $pattern]
    if {[get_collection_size $originals] != 1} { error "Penguin IO original divider missing/ambiguous: $pattern" }
    foreach_in_collection reg $originals { set original_name [get_register_info -name $reg] }
    set c [get_registers $pattern]
    set count [get_collection_size $c]
    if {$count < 1 || $count > $max_live} { error "Penguin IO divider replica count unsupported: $pattern count=$count" }
    foreach_in_collection reg $c {
        set name [get_register_info -name $reg]
        post_message -type info "Penguin IO divider register=$name"
        if {$name ne $original_name && $name ne "${original_name}~DUPLICATE"} { error "Penguin IO unsupported divider replica: $name" }
    }
    return $c
}
proc penguin_io_mcp_pad_source {pad} {
    set fanins [get_fanins -clock $pad]
    set count [get_collection_size $fanins]
    if {$count < 1 || $count > 3} { error "Penguin IO MCP pad fanin count unsupported: $count" }
    set matches 0
    foreach_in_collection node $fanins {
        set name [get_node_info -name $node]
        post_message -type info "Penguin IO MCP pad clock fanin=$name"
        if {$name eq {mcp23009:mcp23009|i2c:i2c|I2C_CLOCK} || $name eq {mcp23009:mcp23009|i2c:i2c|I2C_CLOCK~DUPLICATE}} {
            set selected $node
            incr matches
        } elseif {$name ni {mcp23009:mcp23009|i2c:i2c|SCLK mcp23009:mcp23009|i2c:i2c|SCLK~DUPLICATE}} {
            error "Penguin IO MCP pad unexpected clock fanin: $name"
        }
    }
    if {$matches != 1} { error "Penguin IO expected one physical MCP divider pad source, found=$matches" }
    return $selected
}

proc penguin_io_one_pin {name} {
    set c [get_pins -compatibility_mode $name]
    if {[get_collection_size $c] != 1} { error "Penguin IO expected one mapped pin: $name" }
    return $c
}
proc penguin_io_one_clock {name} {
    set c [get_clocks $name]
    if {[get_collection_size $c] != 1} { error "Penguin IO expected one mapped clock: $name" }
    return $c
}
proc penguin_io_ports {names count} {
    set c [get_ports $names]
    if {[get_collection_size $c] != $count} { error "Penguin IO port count mismatch: $names (expected $count)" }
    return $c
}

# Exact mapped masters from baseline/diagnostic clock report. Fail on drift.
set pio_core_name {emu|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set pio_hdmi_name {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set pio_audio_name {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set pio_core_pin [penguin_io_one_pin $pio_core_name]
set pio_hdmi_pin [penguin_io_one_pin $pio_hdmi_name]
set pio_audio_pin [penguin_io_one_pin $pio_audio_name]
set pio_core_clock [penguin_io_one_clock $pio_core_name]
set pio_hdmi_clock [penguin_io_one_clock $pio_hdmi_name]
set pio_audio_clock [penguin_io_one_clock $pio_audio_name]
# Anchor division at the actual registered output. Official Quartus17
# create_generated_clock targets/sources may be register collections;
# this avoids inventing post-map atom C/Q pin suffixes.
set pio_i2s_divider [penguin_io_one_register {audio_out|i2s|sclk}]
create_generated_clock -name penguin_i2s48 -source $pio_audio_pin \
    -master_clock $pio_audio_clock -divide_by 16 $pio_i2s_divider
create_generated_clock -name penguin_i2s96 -source $pio_audio_pin \
    -master_clock $pio_audio_clock -divide_by 8 -add $pio_i2s_divider

# sys_top1264-1297: mux two real masters; DDR forwards inverted selected clk.
set pio_hdmi_clkport [penguin_io_ports {HDMI_TX_CLK} 1]
create_generated_clock -name penguin_hdmi_scaled -source $pio_hdmi_pin \
    -master_clock $pio_hdmi_clock -divide_by 1 -invert $pio_hdmi_clkport
create_generated_clock -name penguin_hdmi_direct -source $pio_core_pin \
    -master_clock $pio_core_clock -divide_by 1 -invert -add $pio_hdmi_clkport
# Restrict exclusivity to the alternative downstream clocks, not their parents.
set_clock_groups -exclusive -group {penguin_hdmi_scaled} -group {penguin_hdmi_direct}
set pio_video [penguin_io_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS} 27]
# ADV7513 setup1.8/hold1.3 retained; HDMI board flight0..0.3ns declared.
# Primary same-board Intel DE10-Nano reference uses HDMI_PAD0.3ns:
# https://github.com/intel/de10-nano-hardware/blob/master/hdl_src/soc_system_hdmi_timing.sdc
# This is a vendor-reference envelope, NOT a measured trace-delay bound.
# max=setup+Dmax-Cmin=2.1; min=Dmin-Cmax-hold=-1.6.
# Audio/USER bounds below remain independent0..1ns; no delay-contract cut.
set_output_delay -clock penguin_hdmi_scaled -max 2.1 $pio_video
set_output_delay -clock penguin_hdmi_scaled -min -1.6 $pio_video
set_output_delay -clock penguin_hdmi_direct -max 2.1 -add_delay $pio_video
set_output_delay -clock penguin_hdmi_direct -min -1.6 -add_delay $pio_video

# audio_out66-105/i2s18-49: mclkCE ->div2 ->msclk toggle ->registered sclk.
# 24.576MHz /16=1.536MHz BCLK48k; /8=3.072MHz BCLK96k (32bits/stereo).
# Integral parent-cycle reset-origin unspecified: ordinary parent-edge launch
# analysis is conservative. Do NOT add 9/5-cycle CE launch multicycles.
set pio_bclk [penguin_io_ports {HDMI_SCLK} 1]
create_generated_clock -name penguin_bclk48 -source $pio_i2s_divider \
    -master_clock penguin_i2s48 -divide_by 1 $pio_bclk
create_generated_clock -name penguin_bclk96 -source $pio_i2s_divider \
    -master_clock penguin_i2s96 -divide_by 1 -add $pio_bclk
set_clock_groups -exclusive -group {penguin_bclk48} -group {penguin_bclk96}
set pio_audio_data [penguin_io_ports {HDMI_I2S HDMI_LRCLK} 2]
# ADV7513 setup2/hold2 with same independent0..1ns flight bounds =>3/-3.
set_output_delay -clock penguin_bclk48 -max 3.0 $pio_audio_data
set_output_delay -clock penguin_bclk48 -min -3.0 $pio_audio_data
set_output_delay -clock penguin_bclk96 -max 3.0 -add_delay $pio_audio_data
set_output_delay -clock penguin_bclk96 -min -3.0 -add_delay $pio_audio_data
create_generated_clock -name penguin_audio_mclk -source $pio_audio_pin \
    -master_clock $pio_audio_clock -divide_by 1 [penguin_io_ports {HDMI_MCLK} 1]

# SW1 routes BCLK to USER4, SDATA toUSER2, LRCLK toUSER5 through 0/Z OE.
# Same launch stream, but a distinct physical forwarded-clock pad/path.
set pio_user_bclk [penguin_io_ports {USER_IO[4]} 1]
create_generated_clock -name penguin_user_bclk48 -source $pio_i2s_divider \
    -master_clock penguin_i2s48 -divide_by 1 $pio_user_bclk
create_generated_clock -name penguin_user_bclk96 -source $pio_i2s_divider \
    -master_clock penguin_i2s96 -divide_by 1 -add $pio_user_bclk
set_clock_groups -exclusive -group {penguin_i2s48 penguin_bclk48 penguin_user_bclk48} \
    -group {penguin_i2s96 penguin_bclk96 penguin_user_bclk96}
set pio_user_data [penguin_io_ports {USER_IO[2] USER_IO[5]} 2]
# Optional USER I2S receiver contract: setup/hold <=2ns, flight0..1ns.
# Pull-up/threshold/RC delay is ADDITIONAL and remains an unsupported gate.
# Output-delay applies at the pads; root must inspect OE path coverage in STA.
set_output_delay -clock penguin_user_bclk48 -max 3.0 $pio_user_data
set_output_delay -clock penguin_user_bclk48 -min -3.0 $pio_user_data
set_output_delay -clock penguin_user_bclk96 -max 3.0 -add_delay $pio_user_data
set_output_delay -clock penguin_user_bclk96 -min -3.0 -add_delay $pio_user_data

# Owned MCP derivative instantiates100kHz (stock500k had too-short low phase).
# Primary Microchip DS20002121C Table2-4:100k TLOW>=4.7us/THIGH>=4us,
# slave TAA<=3.45us, master setup>=250ns/hold>=0, data hold max3.45us.
# Actual counters: falling I2C_CLOCK -> rising50MHz capture after251cycles
# =5020ns; raw ACK/rdata read only on that CE. No synchronizer invented.
# Supported UNMEASURED pad/protocol envelope: SCL FPGA path<=20ns,
# SCL falling threshold<=40ns, rising threshold<=900ns, boardflight0..1ns
# each direction, slave TAA3.45us under datasheet1kOhm/135pF test load.
# Input budget5020-20-40-2-3450-10guard=1498ns; rawpath bound1450ns.
# Standard17 has no datapath-only/clock-latency-ignore switch. Ordinary
# max/min include clock latency. Supported actual50MHz register clock
# network0..10ns: input max1440 +captureclock<=10 permits rawpath<=1450.
# Output max20/2400 includes nonnegative launchclock, so is conservative
# versus corresponding rawpath bounds. Root MUST verify this clock envelope.
# Next possible slave change is next SCLfall (~4980ns after capture), not
# next50MHz edge. Explicit datapath limits apply ONLY to actual raw endpoints.
set pio_i2c_parent [penguin_io_one_clock FPGA_CLK2_50]
set pio_io_sda [penguin_io_ports {IO_SDA} 1]
# rdata is declared [0:7], with independently indexed captures. MCP uses
# only dout[7:3], hence rdata[0:4]; rdata[5:7] have no live consumers.
# ACK is live: error gates initialization/poll progress. Assert each of
# the six endpoints, and report actual mapped names before any failure.
set pio_i2c_capture [get_registers {mcp23009|i2c|ACK mcp23009|i2c|rdata[*]}]
set pio_i2c_capture_names {}
foreach_in_collection pio_i2c_reg $pio_i2c_capture {
    lappend pio_i2c_capture_names [get_register_info -name $pio_i2c_reg]
}
post_message -type info "Penguin IO MCP capture count=[get_collection_size $pio_i2c_capture] names=$pio_i2c_capture_names"
if {[get_collection_size $pio_i2c_capture] != 6} { error "Penguin IO expected live MCP ACK plus rdata0..4; actual=$pio_i2c_capture_names" }
foreach pio_i2c_endpoint {mcp23009|i2c|ACK {mcp23009|i2c|rdata[0]} {mcp23009|i2c|rdata[1]} {mcp23009|i2c|rdata[2]} {mcp23009|i2c|rdata[3]} {mcp23009|i2c|rdata[4]}} {
    if {[get_collection_size [get_registers $pio_i2c_endpoint]] != 1} { error "Penguin IO missing/ambiguous live MCP endpoint: $pio_i2c_endpoint" }
}
set_max_delay -from $pio_io_sda -to $pio_i2c_capture 1440.0
set_min_delay -from $pio_io_sda -to $pio_i2c_capture 0.0
# Source SDA SDO[3] changes4parent edges80ns after internalSCLfall.
# FPGA SDA path<=2400 +externalrise900 +flight1 +80=3381ns,
# before3.45us maximum data-hold and >250ns before next5us risingSCL.
# Earliest SDA change80ns exceeds worstSCLfall20+40+1=61ns (19ns hold).
set pio_i2c_sdo [get_registers {mcp23009|i2c|SDO[3]}]
if {[get_collection_size $pio_i2c_sdo] != 1} { error "Penguin IO expected actual MCP SDO3 register" }
set_max_delay -from $pio_i2c_sdo -to $pio_io_sda 2400.0
set_min_delay -from $pio_i2c_sdo -to $pio_io_sda 0.0
set pio_i2c_original_launch [get_registers -no_duplicates {mcp23009|i2c|I2C_CLOCK mcp23009|i2c|SCLK}]
if {[get_collection_size $pio_i2c_original_launch] != 2} { error "Penguin IO expected two original MCP SCL launch registers" }
set pio_i2c_scllaunch [get_registers {mcp23009|i2c|I2C_CLOCK mcp23009|i2c|SCLK}]
set pio_i2c_launch_names {}
foreach_in_collection reg $pio_i2c_scllaunch {
    set name [get_register_info -name $reg]
    lappend pio_i2c_launch_names $name
    if {$name ni {mcp23009:mcp23009|i2c:i2c|I2C_CLOCK mcp23009:mcp23009|i2c:i2c|I2C_CLOCK~DUPLICATE mcp23009:mcp23009|i2c:i2c|SCLK mcp23009:mcp23009|i2c:i2c|SCLK~DUPLICATE}} { error "Penguin IO unexpected MCP launch replica: $name" }
}
set pio_i2c_launch_count [get_collection_size $pio_i2c_scllaunch]
post_message -type info "Penguin IO MCP launch count=$pio_i2c_launch_count names=$pio_i2c_launch_names"
if {$pio_i2c_launch_count != 2 && $pio_i2c_launch_count != 3} { error "Penguin IO expected two map or three routed MCP launch registers" }
set_max_delay -from $pio_i2c_scllaunch -to [penguin_io_ports {IO_SCL} 1] 20.0
# PhysicalSCL is gated/stopped high/open-drain. Generated-clock steady-state
# frequency only; no slave capture-phase assertion or constraints on clock as data.
set pio_mcp_divider [penguin_io_one_register {mcp23009|i2c|I2C_CLOCK} 2]
create_generated_clock -name penguin_mcp_divider100k -source [get_ports FPGA_CLK2_50] \
    -master_clock $pio_i2c_parent -divide_by 500 $pio_mcp_divider
set pio_mcp_pad_source [penguin_io_mcp_pad_source [penguin_io_ports {IO_SCL} 1]]
create_generated_clock -name penguin_mcp_scl -source $pio_mcp_pad_source \
    -master_clock penguin_mcp_divider100k -divide_by 1 [penguin_io_ports {IO_SCL} 1]

# Exact special-purpose endpoints. These are interface scope exceptions only;
# never include HDMI video/audio, USER audio, fabric IO_SDA or SDRAM.
# HDMI I2C is HPS hard-IP ownership, not fabric sampled data. Its out_clk is
# an open-drain enable, not an externally meaningful10MHz SCL clock contract.
set_false_path -from [penguin_io_ports {HDMI_I2C_SDA} 1]
set_false_path -to [penguin_io_ports {HDMI_I2C_SDA HDMI_I2C_SCL} 2]
# Async level statuses: HDMI INT ->HPS gp_in; SDCD ->detect/mode control.
# Does NOT certify metastability, debounce, hard-IP polling or mode handover.
set_false_path -from [penguin_io_ports {HDMI_TX_INT SDCD_SPDIF} 2]
# SDCD output carries self-clocking SPDIF on OE (data itself constant0).
set_false_path -to [penguin_io_ports {SDCD_SPDIF} 1]
# SDIO6bits are analog VGA resistor DAC or Z: core SD_SCK/MOSI/CS tiedZ.
# SD_SPI_CS carries inactive-SPI/analog sync mode control, not card transfers.
# If this core later enables SPI, REMOVE these output scope exceptions first.
set_false_path -to [penguin_io_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS} 7]
# Indicators have no synchronous digital capture receiver.
set_false_path -to [penguin_io_ports {LED[0] LED[2] LED[6]} 3]

derive_clock_uncertainty
post_message -type warning "Penguin external IO candidate NOT QUALIFIED: flight/RC/mode/IO_SDA envelope and OE coverage require review; see evidence/native/platform-io-candidate.json"
