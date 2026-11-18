# Receiver capacitance is assigned in alpha68kn_pad_loads.tcl using Cyclone V BOARD_MODEL_FAR_C.
# Declared PAD compatibility profile. No board-flight or arbitrary-module measurement is asserted.
# Load after original primary SDC, core filtered framework SDC, and unchanged game groups.
proc a68_one {c why} {if {[get_collection_size $c] != 1} {error "Expected one $why"}; return $c}
proc a68_count {c n why} {if {[get_collection_size $c] != $n} {error "Expected $n $why"}; return $c}
set a68_g0_pattern {emu|pll|pll|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}
set a68_g1_pattern {emu|pll|pll|general?1?.gpll~PLL_OUTPUT_COUNTER|divclk}
set a68_h_pattern {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter?0?.output_counter|divclk}
set a68_a_pattern {pll_audio|pll_audio_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}
set a68_g0 [a68_one [get_clocks $a68_g0_pattern] game48]
set a68_g1 [a68_one [get_clocks $a68_g1_pattern] shifted_SDRAM48]
set a68_h [a68_one [get_clocks $a68_h_pattern] HDMI_scaled]
set a68_a [a68_one [get_clocks $a68_a_pattern] audio_root]
if {abs([get_clock_info -period $a68_g0]-20.833)>0.002 || abs([get_clock_info -period $a68_g1]-20.833)>0.002} {error {Game/SDRAM root changed}}
if {abs([get_clock_info -period $a68_a]-40.682)>0.002} {error {Audio root changed; re-review CE edge contract}}
if {[get_clock_info -period $a68_h] < 6.060606} {error {ADV7513 maximum 165MHz exceeded}}
set a68_gp0 [a68_one [get_pins -compatibility_mode $a68_g0_pattern] game_PLL_pin]
set a68_gp1 [a68_one [get_pins -compatibility_mode $a68_g1_pattern] shifted_SDRAM_PLL_pin]
set a68_hp [a68_one [get_pins -compatibility_mode $a68_h_pattern] HDMI_PLL_pin]
set a68_ap [a68_one [get_pins -compatibility_mode $a68_a_pattern] audio_PLL_pin]
# Common -7 CL2/BL1 SDRAM Table16. Min0 is first-read tLZ, not burst tOH.
create_generated_clock -name A68N_SDRAM_PAD -divide_by 1 -source $a68_gp1 -master_clock $a68_g1 [a68_one [get_ports SDRAM_CLK] SDRAM_CLK]
set a68_dq [a68_count [get_ports {SDRAM_DQ[*]}] 16 DQ_pads]
set a68_sdo [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_input_delay -clock A68N_SDRAM_PAD -max 6.0 $a68_dq
set_input_delay -clock A68N_SDRAM_PAD -min 0.0 $a68_dq
set_output_delay -clock A68N_SDRAM_PAD -max 1.5 $a68_sdo
set_output_delay -clock A68N_SDRAM_PAD -min -0.8 $a68_sdo
# ADV7513 BA60/no data-clock delay; DDIO clock high0/low1 is inverted.
set a68_hd [a68_count [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 27 HDMI_video_pads]
create_generated_clock -name A68N_HDMI_SCALED_PAD -divide_by 1 -invert -source $a68_hp -master_clock $a68_h [get_ports HDMI_TX_CLK]
create_generated_clock -name A68N_HDMI_DIRECT_PAD -add -divide_by 1 -invert -source $a68_gp0 -master_clock $a68_g0 [get_ports HDMI_TX_CLK]
set_clock_groups -logically_exclusive -group A68N_HDMI_SCALED_PAD -group A68N_HDMI_DIRECT_PAD
foreach a68_clk {A68N_HDMI_SCALED_PAD A68N_HDMI_DIRECT_PAD} {
 set_output_delay -add_delay -clock $a68_clk -max 1.8 $a68_hd
 set_output_delay -add_delay -clock $a68_clk -min -1.3 $a68_hd
}
# Serializer steady epochs only: all unknown CE phases, both 48/96k modes.
create_generated_clock -name A68N_HDMI_MCLK_PAD -divide_by 1 -source $a68_ap -master_clock $a68_a [get_ports HDMI_MCLK]
set a68_audio_regs [a68_count [get_registers {audio_out:audio_out|i2s:i2s|sdata audio_out:audio_out|i2s:i2s|lrclk}] 2 serializer_data_registers]
set a68_audio_data [a68_count [get_ports {HDMI_I2S HDMI_LRCLK USER_IO[2] USER_IO[5] AUDIO_R AUDIO_SPDIF}] 6 I2S_data_aliases]
set a68_audio_clocks {}; set a68_audio_exclusive [list set_clock_groups -logically_exclusive]
foreach a68_rate {48 96} {
 set a68_half [expr {$a68_rate==48?8:4}]
 for {set a68_phase 0} {$a68_phase<2*$a68_half} {incr a68_phase} {
  set a68_edges [list [expr {2*($a68_phase+$a68_half+1)+1}] [expr {2*($a68_phase+2*$a68_half+1)+1}] [expr {2*($a68_phase+3*$a68_half+1)+1}]]
  set a68_phase_group {}
  foreach a68_pad {HDMI_SCLK USER_IO[4] AUDIO_L} {
   set a68_clk A68N_I2S_${a68_rate}_${a68_phase}_[string map [list {[} _ {]} _] $a68_pad]
   create_generated_clock -name $a68_clk -add -edges $a68_edges -source $a68_ap -master_clock $a68_a [get_ports $a68_pad]
   lappend a68_audio_clocks $a68_clk; lappend a68_phase_group $a68_clk
   set_output_delay -add_delay -clock $a68_clk -max 2.0 $a68_audio_data
   set_output_delay -add_delay -clock $a68_clk -min -2.0 $a68_audio_data
   set_multicycle_path -setup -start [expr {$a68_half+1}] -from $a68_audio_regs -to [get_clocks $a68_clk]
   set_multicycle_path -hold -start [expr {2*$a68_half-1}] -from $a68_audio_regs -to [get_clocks $a68_clk]
  }
  lappend a68_audio_exclusive -group $a68_phase_group
 }
}
eval $a68_audio_exclusive
# MCP PAD bit contract: 500k source waveform, FPGA_CLK2_50, not ordinary FM compliance.
# Keep protocol/CB/pull-up/rise-time qualification distinct; unknown phase is enumerated.
set a68_mcp_root [a68_one [get_clocks FPGA_CLK2_50] MCP_root]
set a68_mcp_source [a68_one [get_ports FPGA_CLK2_50] MCP_source]
set a68_mcp_in [a68_count [get_registers {mcp23009:mcp23009|i2c:i2c|ACK mcp23009:mcp23009|i2c:i2c|rdata[*]}] 6 MCP_capture_registers]
set a68_mcp_out [a68_one [get_registers {mcp23009:mcp23009|i2c:i2c|SDO[3]}] MCP_SDA_register]
set a68_mcp_gate [a68_one [get_registers {mcp23009:mcp23009|i2c:i2c|SCLK}] MCP_SCL_gate]
set a68_mcp_clocks {}; set a68_mcp_exclusive [list set_clock_groups -logically_exclusive]
for {set a68_phase 0} {$a68_phase<100} {incr a68_phase} {
 set a68_clk A68N_MCP_SCL_$a68_phase
 create_generated_clock -name $a68_clk -add -source $a68_mcp_source -master_clock $a68_mcp_root -edges [list [expr {2*$a68_phase+1}] [expr {2*($a68_phase+50)+1}] [expr {2*($a68_phase+100)+1}]] [get_ports IO_SCL]
 lappend a68_mcp_clocks $a68_clk; lappend a68_mcp_exclusive -group $a68_clk
 set_input_delay -add_delay -clock $a68_clk -clock_fall -max 900.0 [get_ports IO_SDA]
 set_input_delay -add_delay -clock $a68_clk -clock_fall -min 0.0 [get_ports IO_SDA]
 set_output_delay -add_delay -clock $a68_clk -max 100.0 [get_ports IO_SDA]
 set_output_delay -add_delay -clock $a68_clk -min -10.0 [get_ports IO_SDA]
 set_multicycle_path -setup -end 51 -from [get_clocks $a68_clk] -to $a68_mcp_in
 set_multicycle_path -hold -end 99 -from [get_clocks $a68_clk] -to $a68_mcp_in
 set_multicycle_path -setup -start 46 -from $a68_mcp_out -to [get_clocks $a68_clk]
 set_multicycle_path -hold -start 99 -from $a68_mcp_out -to [get_clocks $a68_clk]
}
eval $a68_mcp_exclusive
set_max_delay 980.0 -from $a68_mcp_gate -to [get_ports IO_SCL]
set_min_delay 0.0 -from $a68_mcp_gate -to [get_ports IO_SCL]
# Extend only explicit operational leaf families; no root descendant sweep.
set a68_families [list [concat [list $a68_g0_pattern $a68_g1_pattern A68N_SDRAM_PAD A68N_HDMI_DIRECT_PAD]] [list $a68_h_pattern A68N_HDMI_SCALED_PAD] [concat [list $a68_a_pattern A68N_HDMI_MCLK_PAD] $a68_audio_clocks] [concat [list FPGA_CLK2_50] $a68_mcp_clocks] [list spi_sck] [list hdmi_sck] [list {*|h2f_user0_clk}] [list FPGA_CLK1_50] [list FPGA_CLK3_50]]
for {set a68_i 0} {$a68_i<[llength $a68_families]} {incr a68_i} {
 for {set a68_j [expr {$a68_i+1}]} {$a68_j<[llength $a68_families]} {incr a68_j} {
  set_clock_groups -asynchronous -group [get_clocks [lindex $a68_families $a68_i]] -group [get_clocks [lindex $a68_families $a68_j]]
 }
}
# Source-specific waveform branches; serializer branches remain timed.
foreach a68_pair [list [list {audio_out:audio_out|sigma_delta_dac:sd_l|DACout} AUDIO_L] [list {audio_out:audio_out|sigma_delta_dac:sd_r|DACout} AUDIO_R] [list {audio_out:audio_out|spdif:toslink|spdif_out_q} {AUDIO_SPDIF SDCD_SPDIF}]] {
 set_false_path -from [a68_one [get_registers [lindex $a68_pair 0]] waveform_source] -to [get_ports [lindex $a68_pair 1]]
}
# Static/asynchronous mode controls only, never serializer data sources.
set_false_path -from [get_ports {SW[0] SW[3] VGA_EN}] -to [get_ports {AUDIO_L AUDIO_R AUDIO_SPDIF}]
set_false_path -from [get_registers {mcp23009:mcp23009|flg_present mcp23009:mcp23009|flg_mode}] -to [get_ports {AUDIO_L AUDIO_R AUDIO_SPDIF SDCD_SPDIF}]
set_false_path -from [get_ports {SW[1]}] -to [get_ports {USER_IO[2] USER_IO[4] USER_IO[5]}]
# Exact hard-HPS-owned I2C/status boundaries have no fabric launch/capture clock.
set_false_path -from [a68_one [get_registers {hdmi_i2c~FF_4791}] HPS_SDA_output] -to [get_ports HDMI_I2C_SDA]
set_false_path -from [a68_one [get_registers {hdmi_i2c~FF_4792}] HPS_SCL_output] -to [get_ports HDMI_I2C_SCL]
set_false_path -from [get_ports HDMI_I2C_SDA] -to [a68_one [get_registers {hdmi_i2c~FF_3392}] HPS_SDA_input]
set_false_path -from [get_ports HDMI_TX_INT] -to [a68_one [get_registers {h2f_gp~FF_186}] HPS_HDMI_status]
# Analog/self-timed VGA/SD aliases; core SD clock/data outputs are inactive constants.
set_false_path -from [get_ports SDCD_SPDIF] -to [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*]}]
set_false_path -to [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS LED[0] LED[2] LED[6]}]
# Deliberately no global AUDIO/USER/HDMI/SDRAM false path or same-family CDC cut.
