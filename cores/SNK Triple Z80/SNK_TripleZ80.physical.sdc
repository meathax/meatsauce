# Candidate only. Pin-receiver timing: ADV7513 Rev B pp3-4.
# PCB data-minus-forwarded-clock differential flight: +/-0.3ns conservative
# design bound; not measured. No internal ADV0xBA delay credit is taken.
# Requires SDR RGB input / rising video capture and rising I2S capture (0x0B[6]=0).
# Source exact current-fit PLL names and both actual mux modes; pinned sys unchanged.
# This file is read before SNK_TripleZ80.sdc/sys_top.sdc, so PLL clocks must exist before the lookups below.
derive_pll_clocks
proc snk_io_one {c label} {
 if {[get_collection_size $c] != 1} {error "SNK IO cardinality $label"}
 return $c
}
# Runtime family PLL (rtl/snk/clock/snk_pll_mode.sv): derive_pll_clocks gives the power-up 96 MHz setting (K 9.6). The
# 93.8 MHz setting (K 9.38) clocks SNK_SYS_938 / SNK_SDR_938 are created in SNK_TripleZ80.sdc, which the
# fitter reads BEFORE this file; this file uses them and declares the 96/93.8 MHz exclusion at its end.
set snk_sys_938 SNK_SYS_938
set snk_sdr_938 SNK_SDR_938
set snk_hdmi_master {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set snk_direct_master {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set snk_audio_master {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set snk_hdmi_video [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $snk_hdmi_video] != 27} {error {SNK HDMI video coverage}}
# Direct video forwards clk_sys: one forwarded clock per PLL setting (source pin = the outclk_0 counter in both).
foreach {name master pin} [list SNK_HDMI_SCALED $snk_hdmi_master $snk_hdmi_master SNK_HDMI_DIRECT $snk_direct_master $snk_direct_master SNK_HDMI_DIRECT_938 $snk_sys_938 $snk_direct_master] {
 snk_io_one [get_clocks $master] $name
 set src [snk_io_one [get_pins -compatibility_mode [list $pin]] $name]
 create_generated_clock -name $name -master_clock $master -source $src -divide_by 1 -invert -add [get_ports HDMI_TX_CLK]
 set_output_delay -clock $name -max 2.1 -add_delay $snk_hdmi_video
 set_output_delay -clock $name -min -1.6 -add_delay $snk_hdmi_video
}
# Only the two forwarded capture modes are mutually exclusive. Both original
# master clocks remain concurrently active; pinned baseline master cuts are
# unchanged. Exclude only the source-proven mismatched external capture pairs.
set_clock_groups -exclusive -group [get_clocks SNK_HDMI_SCALED] -group [get_clocks {SNK_HDMI_DIRECT SNK_HDMI_DIRECT_938}]
set_false_path -from [get_clocks $snk_hdmi_master] -to [get_clocks {SNK_HDMI_DIRECT SNK_HDMI_DIRECT_938}]
set_false_path -from [get_clocks [list $snk_direct_master $snk_sys_938]] -to [get_clocks SNK_HDMI_SCALED]
set snk_audio_src [snk_io_one [get_pins -compatibility_mode [list $snk_audio_master]] audio_source]
create_generated_clock -name SNK_HDMI_MCLK -master_clock $snk_audio_master -source $snk_audio_src -divide_by 1 [get_ports HDMI_MCLK]
foreach {name divisor} {SNK_HDMI_SCLK_48 16 SNK_HDMI_SCLK_96 8} {
 set core ${name}_CORE
 set snk_sclk_reg [snk_io_one [get_registers {audio_out:audio_out|i2s:i2s|sclk}] audio_divider]
 create_generated_clock -name $core -master_clock $snk_audio_master -source $snk_audio_src -divide_by $divisor -add $snk_sclk_reg
 create_generated_clock -name $name -master_clock $core -source $snk_sclk_reg -divide_by 1 -add [get_ports HDMI_SCLK]
 set_output_delay -clock $name -max 2.3 -add_delay [get_ports {HDMI_I2S HDMI_LRCLK}]
 set_output_delay -clock $name -min -2.3 -add_delay [get_ports {HDMI_I2S HDMI_LRCLK}]
 # USER_IO exports open-drain I2S only; other user_out values in this core are
 # constant1/high-Z. Receiver contract: setup/hold <=2ns, differential pin-to-
 # receiver flight/rise skew <=5ns. These are declared limits, not measurements.
 set user_clock SNK_USER_SCLK_[expr {$divisor==16 ? 48 : 96}]
 create_generated_clock -name $user_clock -master_clock $core -source $snk_sclk_reg -divide_by 1 -add [get_ports {USER_IO[4]}]
 set_output_delay -clock $user_clock -max 7.0 -add_delay [get_ports {USER_IO[2] USER_IO[5]}]
 set_output_delay -clock $user_clock -min -7.0 -add_delay [get_ports {USER_IO[2] USER_IO[5]}]
}
set_clock_groups -exclusive -group [get_clocks {SNK_HDMI_SCLK_48_CORE SNK_HDMI_SCLK_48 SNK_USER_SCLK_48}] -group [get_clocks {SNK_HDMI_SCLK_96_CORE SNK_HDMI_SCLK_96 SNK_USER_SCLK_96}]
# Original i2s.v phase proof,352 data/LR transitions: enabled source updates
# 7 master edges after48k SCLK rise,3 edges after96k rise. Restrict hold check
# to the two actual data registers and the exact matching forwarded clocks.
# Setup remains the conservative every-master-edge check; no setup relaxation.
set snk_audio_data [get_registers {audio_out:audio_out|i2s:i2s|sdata audio_out:audio_out|i2s:i2s|lrclk}]
if {[get_collection_size $snk_audio_data]!=2} {error {SNK audio data coverage}}
set_multicycle_path 7 -hold -start -from $snk_audio_data -to [get_clocks {SNK_HDMI_SCLK_48 SNK_USER_SCLK_48}]
set_multicycle_path 3 -hold -start -from $snk_audio_data -to [get_clocks {SNK_HDMI_SCLK_96 SNK_USER_SCLK_96}]
# Exact3 independent DE10 indication LEDs: no sequential receiver or clock view.
# LED_USER forwards VGA clock and is deliberately excluded.
set snk_indicators [get_ports {LED[0] LED[2] LED[6]}]
if {[get_collection_size $snk_indicators] != 3} {error {SNK indicator coverage}}
set_false_path -to $snk_indicators
# Continuous resistor-DAC video/YC and sync-on-green outputs have no clocked
# receiver. Apply explicit clock-to-pad route latency limits, not false paths.
# This core drives secondary SD outputs high-Z; exact fitted fanins prove the
# remaining data producers are native/scaler VGA and YC, plus static mux controls.
set snk_analog [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS}]
if {[get_collection_size $snk_analog]!=7} {error {SNK analog coverage}}
set snk_analog_regs [get_fanins $snk_analog]
set snk_analog_clock_pins {}
foreach_in_collection n $snk_analog_regs {
 if {[get_node_info -type $n] ne "reg"} {continue}
 foreach edge [get_node_info -clock_edges $n] {
  lappend snk_analog_clock_pins [get_node_info -name [get_edge_info -src $edge]]
 }
}
set snk_analog_launch [get_pins -compatibility_mode [lsort -unique $snk_analog_clock_pins]]
if {[get_collection_size $snk_analog_launch]<10} {error {SNK analog producer coverage}}
# Declared total clock-to-pad latency ceiling30ns; continuous output has no
# sequential receiver. Includes clock distribution, not just data routing.
set_max_delay 30.0 -from $snk_analog_launch -to $snk_analog
set_min_delay 0.0 -from $snk_analog_launch -to $snk_analog
# SD card detect has only combinational fanout to the six analog output muxes in
# this fitted core. Mechanical status changes have an explicit10ns route bound;
# there is no sequential data receiver/SD transaction in this graph.
set snk_detect_outputs [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*]}]
set_max_delay 30.0 -from [get_ports SDCD_SPDIF] -to $snk_detect_outputs
set_min_delay 0.0 -from [get_ports SDCD_SPDIF] -to $snk_detect_outputs
# Self-clocked S/PDIF drives an unclocked physical receiver, with a30ns total
# latency budget relative to its actual serializer clock pin. No data path cut.
set snk_spdif_pins {}
set snk_spdif_producers {}
foreach_in_collection reg [get_fanins [get_ports SDCD_SPDIF]] {
 if {[get_node_info -type $reg] ne "reg"} {continue}
 set name [get_node_info -name $reg]
 if {![string match {*toslink*spdif_out_q*} $name]} {continue}
 lappend snk_spdif_producers $name
 foreach edge [get_node_info -clock_edges $reg] {lappend snk_spdif_pins [get_node_info -name [get_edge_info -src $edge]]}
}
if {[llength $snk_spdif_producers]<1} {error {SNK SPDIF actual serializer fanin missing}}
set snk_spdif_source [get_pins -compatibility_mode [lsort -unique $snk_spdif_pins]]
if {[get_collection_size $snk_spdif_source]<1} {error {SNK SPDIF serializer clock boundary missing}}
set_max_delay 30.0 -from $snk_spdif_source -to [get_ports SDCD_SPDIF]
set_min_delay 0.0 -from $snk_spdif_source -to [get_ports SDCD_SPDIF]
# IRQ is a persistent asynchronous status input routed only to FPGA-manager GPI.
# Primary CycloneV cv_5v4 2014-12-15 p4-9 explicitly synchronizes all GPI inputs
# within the manager. Current-fit boundary h2f_gp~FF_186 has no fabric clock edge.
# Bound only the pin->actual hard-IP input route; downstream ASIC synchronizers
# are outside fabric timing. No other input or sequential path is excepted.
set snk_irq_boundary [snk_io_one [get_registers {h2f_gp~FF_186}] irq_boundary]
if {[get_collection_size [get_fanouts [get_ports HDMI_TX_INT]]]!=1} {error {SNK IRQ fanout changed}}
set_max_delay 8.0 -from [get_ports HDMI_TX_INT] -to $snk_irq_boundary
set_min_delay 0.0 -from [get_ports HDMI_TX_INT] -to $snk_irq_boundary
# Fabric MCP23009 bus. Original RTL phase proof: SCL half-cycle1000ns,
# actual ACK/rdata capture rising+20ns, data transition falling+80ns.
# DS20002121C high-speed-mode TAA<=180ns; external differential/rise budget
# <=20ns gives1020-180-20=820ns available pin-to-capture latency.
# This conditional contract requires2.7..5.5V and CB<=100pF supported mode.
# It does not qualify an unknown board in400kHz/CB<=400pF mode at500kHz.
set snk_mcp_inputs [get_registers {mcp23009:mcp23009|i2c:i2c|ACK mcp23009:mcp23009|i2c:i2c|rdata[*]}]
if {[get_collection_size $snk_mcp_inputs]!=6} {error {SNK MCP receiver coverage}}
set_max_delay 820.0 -from [get_ports IO_SDA] -to $snk_mcp_inputs
# Next legal peripheral data change is next SCL fall,980ns after capture.
# Minus20ns external uncertainty leaves960ns hold margin. Explicit signed
# min-delay expresses that protocol phase against TimeQuest's unclocked input
# boundary; a same-edge zero-min model does not describe this enabled receiver.
# An MCP-only hold multicycle has no effect with explicit min/max delays.
set_min_delay -960.0 -from [get_ports IO_SDA] -to $snk_mcp_inputs
# SDA clock-to-pad30ns plus proved80ns phase is110ns after falling,
# leaving890ns before rising, above10ns receiver setup plus20ns external.
# SCL is an actual clock waveform; bound its two physical producer routes too.
foreach port {IO_SDA IO_SCL} {
 set pins {}
 set producers {}
 foreach_in_collection reg [get_fanins [get_ports $port]] {
  if {[get_node_info -type $reg] ne "reg"} {continue}
  set name [get_node_info -name $reg]
  if {![string match {mcp23009:mcp23009|i2c:i2c|*} $name]} {error "SNK unexpected MCP output producer $name"}
  lappend producers $name
  foreach edge [get_node_info -clock_edges $reg] {lappend pins [get_node_info -name [get_edge_info -src $edge]]}
 }
 if {[llength $producers]<1} {error "SNK actual MCP output producer missing $port"}
 set src [get_pins -compatibility_mode [lsort -unique $pins]]
 if {[get_collection_size $src]<1} {error "SNK actual MCP output clock missing $port"}
 set_max_delay 30.0 -from $src -to [get_ports $port]
 set_min_delay 0.0 -from $src -to [get_ports $port]
}
# HPS I2C is a hard-IP boundary with no fabric clock-edge metadata. Bound the
# actual fabric pin routes individually. Native hard-IP/software qualification
# remains conditional: <=400kHz, SDA setup/hold>=150ns at hard boundary, and
# external flight/rise uncertainty<=20ns meet ADV7513's100ns setup/hold.
# No claim that Template's hdmi_sck10MHz placeholder establishes bus frequency.
set snk_hps_sda_in [snk_io_one [get_registers {hdmi_i2c~FF_3392}] hps_sda_input]
set_max_delay 30.0 -from [get_ports HDMI_I2C_SDA] -to $snk_hps_sda_in
set_min_delay 0.0 -from [get_ports HDMI_I2C_SDA] -to $snk_hps_sda_in
foreach {port keeper} {HDMI_I2C_SDA {hdmi_i2c~FF_4791} HDMI_I2C_SCL {hdmi_i2c~FF_4792}} {
 set reg [snk_io_one [get_registers [list $keeper]] hps_i2c_output]
 set_max_delay 30.0 -from $reg -to [get_ports $port]
 set_min_delay 0.0 -from $reg -to [get_ports $port]
}
derive_clock_uncertainty
set snk_hps_scl_source [snk_io_one [get_pins -compatibility_mode {hdmi_i2c|out_clk}] hps_clock_source]
set_max_delay 30.0 -from $snk_hps_scl_source -to [get_ports HDMI_I2C_SCL]
set_min_delay 0.0 -from $snk_hps_scl_source -to [get_ports HDMI_I2C_SCL]
# Real50MHz PLL-reconfiguration hold repair: explicit0.10ns minimum delay
# strengthens the native0.05ns endpoint hold requirement; original20ns setup
# relationship, real clock insertion and CPR remain untouched. Actual source
# must be the pinned local_reset producer (including physical duplicates).
# Two reconfiguration blocks now exist: sys_top's pll_cfg_hdmi and the core's game-PLL pll_cfg (snk_pll_mode). Each has one
# PLL_RECONFIG capture register and its own local_reset producer; the same hold repair applies to each pair.
set snk_pll_cfg_sinks [get_registers {*PLL_RECONFIG~FMAX_CAP_FF}]
if {[get_collection_size $snk_pll_cfg_sinks] < 1} {error {SNK PLL-reconfiguration capture register missing}}
set snk_pll_cfg_paired 0
foreach_in_collection snk_pll_cfg_id $snk_pll_cfg_sinks {
 set snk_pll_cfg_sink [get_registers [get_register_info -name $snk_pll_cfg_id]]
 if {[get_collection_size $snk_pll_cfg_sink] != 1} {error {SNK PLL-reconfiguration capture register name did not resolve}}
 set snk_pll_cfg_sources {}
 foreach_in_collection n [get_fanins $snk_pll_cfg_sink] {
  if {[get_node_info -type $n] ne "reg"} {continue}
  set name [get_node_info -name $n]
  if {[string match {*self_reset:self_reset_inst|local_reset*} $name]} {lappend snk_pll_cfg_sources $name}
 }
 if {[llength $snk_pll_cfg_sources]<1} {continue}
 set snk_pll_cfg_from [get_registers $snk_pll_cfg_sources]
 set_min_delay 0.10 -from $snk_pll_cfg_from -to $snk_pll_cfg_sink
 incr snk_pll_cfg_paired
}
if {$snk_pll_cfg_paired < 1} {error {SNK PLL-reconfiguration real reset producer missing}}
# One K is programmed at a time: the 96 MHz and 93.8 MHz clock sets on the same PLL/port nets never coexist.
set snk_set_96 [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk SNK_SDRAM_CLK SNK_HDMI_DIRECT}]
set snk_set_938 [get_clocks {SNK_SYS_938 SNK_SDR_938 SNK_SDRAM_CLK_938 SNK_HDMI_DIRECT_938}]
if {[get_collection_size $snk_set_96] != 4 || [get_collection_size $snk_set_938] != 4} {error {SNK runtime PLL clock sets unresolved}}
set_clock_groups -physically_exclusive -group $snk_set_96 -group $snk_set_938
