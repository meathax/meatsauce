# Private check candidate: selected R8 source, declared compatible interfaces.
# No measured PCB/module identity, no release acceptance implied.
# Source after the existing PLL/SDRAM timing files.
# Exact native max/min event propagation requirements do not create CE clocks.
proc mf145_port {name} {
 set pattern [string map [list {[} {?} {]} {?}] $name]
 set c [get_ports $pattern]
 if {[get_collection_size $c] != 1} {error "Required selected port missing/ambiguous: $name"}
 foreach_in_collection id $c {if {[get_port_info -name $id] ne $name} {error "Port identity mismatch: $name"}}
 return $c
}
proc mf145_clock {name} {
 set pattern [string map [list {[} {?} {]} {?}] $name]
 set c [get_clocks $pattern]
 if {[get_collection_size $c] != 1} {error "Required native clock missing/ambiguous: $name"}
 foreach_in_collection id $c {if {[get_clock_info -name $id] ne $name} {error "Clock identity mismatch: $name"}}
 return $c
}
proc mf145_clock_target_name {clock} {
 if {[get_collection_size $clock] != 1} {error "Exact native master clock collection required"}
 foreach_in_collection id $clock {set targets [get_clock_info -targets $id]}
 if {[get_collection_size $targets] != 1} {error "Unique native clock target collection required"}
 foreach_in_collection target $targets {set name [get_node_info -name $target]}
 return $name
}
proc mf145_clock_source {clock} {
 set name [mf145_clock_target_name $clock]
 set c [get_pins [string map [list {[} {?} {]} {?}] $name]]
 if {[get_collection_size $c] != 1} {error "Unique native clock source pin required: $name"}
 foreach_in_collection pin $c {if {[get_node_info -name $pin] ne $name} {error "Native clock source pin identity mismatch: $name"}}
 return $c
}
proc mf145_propagation {name low high reason} {
 set c [mf145_port $name]
 # TimeQuest17 maximum/minimum delays admit ports without I/O delays.
 # These bounds include source clock network and CQ/route, not just PCB flight.
 # They preserve real active paths. A zero topology remains an observation.
 set_max_delay $high -to $c
 set_min_delay $low -to $c
}
set mf145_expected {{FPGA_CLK1_50} {FPGA_CLK2_50} {FPGA_CLK3_50} {HDMI_I2C_SCL} {HDMI_I2C_SDA} {HDMI_MCLK} {HDMI_SCLK} {HDMI_LRCLK} {HDMI_I2S} {HDMI_TX_CLK} {HDMI_TX_DE} {HDMI_TX_D[0]} {HDMI_TX_D[1]} {HDMI_TX_D[2]} {HDMI_TX_D[3]} {HDMI_TX_D[4]} {HDMI_TX_D[5]} {HDMI_TX_D[6]} {HDMI_TX_D[7]} {HDMI_TX_D[8]} {HDMI_TX_D[9]} {HDMI_TX_D[10]} {HDMI_TX_D[11]} {HDMI_TX_D[12]} {HDMI_TX_D[13]} {HDMI_TX_D[14]} {HDMI_TX_D[15]} {HDMI_TX_D[16]} {HDMI_TX_D[17]} {HDMI_TX_D[18]} {HDMI_TX_D[19]} {HDMI_TX_D[20]} {HDMI_TX_D[21]} {HDMI_TX_D[22]} {HDMI_TX_D[23]} {HDMI_TX_HS} {HDMI_TX_VS} {HDMI_TX_INT} {SDRAM_A[0]} {SDRAM_A[1]} {SDRAM_A[2]} {SDRAM_A[3]} {SDRAM_A[4]} {SDRAM_A[5]} {SDRAM_A[6]} {SDRAM_A[7]} {SDRAM_A[8]} {SDRAM_A[9]} {SDRAM_A[10]} {SDRAM_A[11]} {SDRAM_A[12]} {SDRAM_DQ[0]} {SDRAM_DQ[1]} {SDRAM_DQ[2]} {SDRAM_DQ[3]} {SDRAM_DQ[4]} {SDRAM_DQ[5]} {SDRAM_DQ[6]} {SDRAM_DQ[7]} {SDRAM_DQ[8]} {SDRAM_DQ[9]} {SDRAM_DQ[10]} {SDRAM_DQ[11]} {SDRAM_DQ[12]} {SDRAM_DQ[13]} {SDRAM_DQ[14]} {SDRAM_DQ[15]} {SDRAM_DQML} {SDRAM_DQMH} {SDRAM_nWE} {SDRAM_nCAS} {SDRAM_nRAS} {SDRAM_nCS} {SDRAM_BA[0]} {SDRAM_BA[1]} {SDRAM_CLK} {SDRAM_CKE} {VGA_R[0]} {VGA_R[1]} {VGA_R[2]} {VGA_R[3]} {VGA_R[4]} {VGA_R[5]} {VGA_G[0]} {VGA_G[1]} {VGA_G[2]} {VGA_G[3]} {VGA_G[4]} {VGA_G[5]} {VGA_B[0]} {VGA_B[1]} {VGA_B[2]} {VGA_B[3]} {VGA_B[4]} {VGA_B[5]} {VGA_HS} {VGA_VS} {VGA_EN} {AUDIO_L} {AUDIO_R} {AUDIO_SPDIF} {SDIO_DAT[0]} {SDIO_DAT[1]} {SDIO_DAT[2]} {SDIO_DAT[3]} {SDIO_CMD} {SDIO_CLK} {LED_USER} {LED_HDD} {LED_POWER} {LED[0]} {LED[1]} {LED[2]} {LED[3]} {LED[4]} {LED[5]} {LED[6]} {LED[7]} {BTN_USER} {BTN_OSD} {BTN_RESET} {KEY[0]} {KEY[1]} {SD_SPI_CS} {SD_SPI_MISO} {SD_SPI_CLK} {SD_SPI_MOSI} {SDCD_SPDIF} {IO_SCL} {IO_SDA} {ADC_SCK} {ADC_SDO} {ADC_SDI} {ADC_CONVST} {SW[0]} {SW[1]} {SW[2]} {SW[3]} {USER_IO[0]} {USER_IO[1]} {USER_IO[2]} {USER_IO[3]} {USER_IO[4]} {USER_IO[5]} {USER_IO[6]}}
set mf145_all [get_ports *]
if {[get_collection_size $mf145_all] != 145} {error "Selected native145 port catalog required"}
foreach mf145_name $mf145_expected {mf145_port $mf145_name}
set mf145_c4 [mf145_clock {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]
set mf145_c4_source [mf145_clock_source $mf145_c4]
set mf145_hdmi [mf145_clock {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set mf145_hdmi_source [mf145_clock_source $mf145_hdmi]
set mf145_audio [mf145_clock {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set mf145_audio_source [mf145_clock_source $mf145_audio]
# Actual HDMI DDR output is inverted; direct/scaler clocks are mux alternatives.
foreach {label clock source} [list C4 $mf145_c4 $mf145_c4_source PLL $mf145_hdmi $mf145_hdmi_source] {
 foreach_in_collection id $clock {set master [get_clock_info -name $id]}
 create_generated_clock -name HDMI_PAD_$label -master_clock $master -source $source -divide_by 1 -invert -add [mf145_port HDMI_TX_CLK]
}
# The output mux selects one matching clock/data family. Both oscillators may
# run, but PLL data can never be sampled by the direct-video pad clock (or vice
# versa). Retain both real same-mode setup/hold checks and all related C3/C4/C5 paths.
set mf145_c4_family [get_clocks {HDMI_PAD_C4 emu|pll|pll_inst|altera_pll_i|general?4?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set mf145_hdmi_family [get_clocks {HDMI_PAD_PLL pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter?0?.output_counter|divclk}]
if {[get_collection_size $mf145_c4_family] != 2 || [get_collection_size $mf145_hdmi_family] != 2} {error "HDMI mode clock families must each contain exactly one master and one pad clock"}
set_clock_groups -exclusive -group $mf145_c4_family -group $mf145_hdmi_family
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_DE}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_DE}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[0]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[0]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[1]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[1]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[2]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[2]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[3]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[3]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[4]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[4]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[5]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[5]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[6]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[6]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[7]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[7]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[8]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[8]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[9]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[9]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[10]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[10]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[11]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[11]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[12]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[12]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[13]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[13]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[14]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[14]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[15]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[15]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[16]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[16]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[17]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[17]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[18]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[18]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[19]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[19]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[20]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[20]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[21]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[21]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[22]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[22]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_D[23]}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_D[23]}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_HS}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_HS}]}
foreach mf145_hclock {HDMI_PAD_C4 HDMI_PAD_PLL} {set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -max 2.310 [mf145_port {HDMI_TX_VS}]; set_output_delay -clock [get_clocks $mf145_hclock] -add_delay -min -1.810 [mf145_port {HDMI_TX_VS}]}
# At96k each data update precedes BCLK rise5 audio roots and next data3 roots.
# Native event insertions of both data and clock are required in[0,2Taudio].
# With receiver65.105ns and external skew+jitter11ns: setup45.94ns/hold29.68ns.
# This is a latency envelope preserving event association, not a fake CE clock.
mf145_propagation {HDMI_MCLK} 0.000 81.364 audio_event_envelope
mf145_propagation {HDMI_SCLK} 0.000 81.364 audio_event_envelope
mf145_propagation {HDMI_LRCLK} 0.000 81.364 audio_event_envelope
mf145_propagation {HDMI_I2S} 0.000 81.364 audio_event_envelope
mf145_propagation {AUDIO_L} 0.000 81.364 audio_event_envelope
mf145_propagation {AUDIO_R} 0.000 81.364 audio_event_envelope
mf145_propagation {AUDIO_SPDIF} 0.000 81.364 audio_event_envelope
mf145_propagation {SDCD_SPDIF} 0.000 81.364 audio_event_envelope
mf145_propagation {USER_IO[2]} 0.000 81.364 audio_event_envelope
mf145_propagation {USER_IO[4]} 0.000 81.364 audio_event_envelope
mf145_propagation {USER_IO[5]} 0.000 81.364 audio_event_envelope
mf145_propagation {USER_IO[0]} 0.000 20.833 C4_retimed_gpio_waveform
mf145_propagation {USER_IO[1]} 0.000 20.833 C4_retimed_gpio_waveform
mf145_propagation {USER_IO[3]} 0.000 20.833 C4_retimed_gpio_waveform
mf145_propagation {USER_IO[6]} 0.000 20.833 C4_retimed_gpio_waveform
set_max_delay 20.000 -from [mf145_port {BTN_USER}]
set_min_delay 0.000 -from [mf145_port {BTN_USER}]
set_max_delay 20.000 -from [mf145_port {BTN_OSD}]
set_min_delay 0.000 -from [mf145_port {BTN_OSD}]
set_max_delay 20.000 -from [mf145_port {BTN_RESET}]
set_min_delay 0.000 -from [mf145_port {BTN_RESET}]
set_max_delay 20.000 -from [mf145_port {KEY[0]}]
set_min_delay 0.000 -from [mf145_port {KEY[0]}]
set_max_delay 20.000 -from [mf145_port {KEY[1]}]
set_min_delay 0.000 -from [mf145_port {KEY[1]}]
set_max_delay 20.000 -from [mf145_port {SW[0]}]
set_min_delay 0.000 -from [mf145_port {SW[0]}]
set_max_delay 20.000 -from [mf145_port {SW[1]}]
set_min_delay 0.000 -from [mf145_port {SW[1]}]
set_max_delay 20.000 -from [mf145_port {SW[2]}]
set_min_delay 0.000 -from [mf145_port {SW[2]}]
set_max_delay 20.000 -from [mf145_port {SW[3]}]
set_min_delay 0.000 -from [mf145_port {SW[3]}]
set_max_delay 20.000 -from [mf145_port {VGA_EN}]
set_min_delay 0.000 -from [mf145_port {VGA_EN}]
set_max_delay 20.000 -from [mf145_port {SDCD_SPDIF}]
set_min_delay 0.000 -from [mf145_port {SDCD_SPDIF}]
mf145_propagation {IO_SCL} 0.000 100.000 MCP_output_fall_pipeline
mf145_propagation {IO_SDA} 0.000 100.000 MCP_output_fall_pipeline
set_max_delay 619.000 -from [mf145_port IO_SDA] -to [get_clocks FPGA_CLK2_50]
set_min_delay 0.000 -from [mf145_port IO_SDA] -to [get_clocks FPGA_CLK2_50]
# Selected video/status13.464ns is a declared propagation bound, NOT half C4 period.
# All-mode edge/pixel skew and pulse integrity require separate actual native proof.
mf145_propagation {VGA_R[0]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_R[1]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_R[2]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_R[3]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_R[4]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_R[5]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[0]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[1]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[2]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[3]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[4]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_G[5]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[0]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[1]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[2]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[3]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[4]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_B[5]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_HS} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {VGA_VS} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_DAT[0]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_DAT[1]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_DAT[2]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_DAT[3]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_CMD} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {SDIO_CLK} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED_USER} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED_HDD} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED_POWER} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[0]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[1]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[2]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[3]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[4]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[5]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[6]} 0.000 13.464 selected_video_status_event_latency
mf145_propagation {LED[7]} 0.000 13.464 selected_video_status_event_latency
set_max_delay 20.000 -from [mf145_port {HDMI_I2C_SCL}]
set_min_delay 0.000 -from [mf145_port {HDMI_I2C_SCL}]
mf145_propagation {HDMI_I2C_SCL} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {HDMI_I2C_SDA}]
set_min_delay 0.000 -from [mf145_port {HDMI_I2C_SDA}]
mf145_propagation {HDMI_I2C_SDA} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {HDMI_TX_INT}]
set_min_delay 0.000 -from [mf145_port {HDMI_TX_INT}]
mf145_propagation {HDMI_TX_INT} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {SD_SPI_CS}]
set_min_delay 0.000 -from [mf145_port {SD_SPI_CS}]
mf145_propagation {SD_SPI_CS} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {SD_SPI_MISO}]
set_min_delay 0.000 -from [mf145_port {SD_SPI_MISO}]
mf145_propagation {SD_SPI_MISO} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {SD_SPI_CLK}]
set_min_delay 0.000 -from [mf145_port {SD_SPI_CLK}]
mf145_propagation {SD_SPI_CLK} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {SD_SPI_MOSI}]
set_min_delay 0.000 -from [mf145_port {SD_SPI_MOSI}]
mf145_propagation {SD_SPI_MOSI} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {ADC_SCK}]
set_min_delay 0.000 -from [mf145_port {ADC_SCK}]
mf145_propagation {ADC_SCK} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {ADC_SDO}]
set_min_delay 0.000 -from [mf145_port {ADC_SDO}]
mf145_propagation {ADC_SDO} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {ADC_SDI}]
set_min_delay 0.000 -from [mf145_port {ADC_SDI}]
mf145_propagation {ADC_SDI} 0.000 100.000 source_static_or_hardIP_direction_review
set_max_delay 20.000 -from [mf145_port {ADC_CONVST}]
set_min_delay 0.000 -from [mf145_port {ADC_CONVST}]
mf145_propagation {ADC_CONVST} 0.000 100.000 source_static_or_hardIP_direction_review

# Conditional design electrical requirements, not PCB measurements.
# Source after the existing C3/forward-clock/16-capture constraint file.
# Keep its exact setup-start2/hold-start1 word association unchanged.
# This file covers SDRAM only; it does not claim complete external-I/O closure.
# READ: tACmax + clock-flight + DQ-return <= 6.300 ns.
#       tOHmin + earliest clock-flight/DQ-return >= 2.500 ns.
# WRITE/CA/DQM: receiver setup + (data-flight - clock-flight) <= 1.540 ns.
#       receiver hold - (data-flight - clock-flight) <= 1.300 ns.
# Reference chip tAC6/tOH2.5/setup1.5/hold.8 permits matched write skew
# [-.500,+.040] ns. Faster compatible devices can trade tAC for transport.
# Exact fixed-profile native CPPR de-pessimization and uncertainty remain STA
# checks, never pad propagation delays; all-corner natural timing is required.

proc metamorphic_exact_sdram_port_r2 {name} {
    set pattern [string map [list {[} {?} {]} {?}] $name]
    set ports [get_ports $pattern]
    if {[get_collection_size $ports] != 1} {error "Exact SDRAM port singleton required: $name"}
    foreach_in_collection port $ports {
        if {[get_port_info -name $port] ne $name} {error "SDRAM native port name mismatch: $name"}
    }
    return $ports
}
set mf_forward_r2 [get_clocks {SDRAM_CLK}]
if {[get_collection_size $mf_forward_r2] != 1} {error "Exact existing SDRAM_CLK required"}
foreach_in_collection mf_clock_r2 $mf_forward_r2 {
    if {[get_clock_info -name $mf_clock_r2] ne "SDRAM_CLK"} {error "SDRAM forward clock identity mismatch"}
    if {abs([get_clock_info -period $mf_clock_r2] - 10.416667) > .003} {error "96MHz SDRAM contract only"}
}
for {set mf_bit_r2 0} {$mf_bit_r2 < 16} {incr mf_bit_r2} {
    set mf_port_r2 [metamorphic_exact_sdram_port_r2 [format {SDRAM_DQ[%d]} $mf_bit_r2]]
    set_input_delay -clock $mf_forward_r2 -max 6.300 $mf_port_r2
    set_input_delay -clock $mf_forward_r2 -min 2.500 $mf_port_r2
    set_output_delay -clock $mf_forward_r2 -max 1.540 $mf_port_r2
    set_output_delay -clock $mf_forward_r2 -min -1.300 $mf_port_r2
}
set mf_ca_names_r2 {SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS}
for {set mf_bit_r2 0} {$mf_bit_r2 < 13} {incr mf_bit_r2} {lappend mf_ca_names_r2 [format {SDRAM_A[%d]} $mf_bit_r2]}
for {set mf_bit_r2 0} {$mf_bit_r2 < 2} {incr mf_bit_r2} {lappend mf_ca_names_r2 [format {SDRAM_BA[%d]} $mf_bit_r2]}
foreach mf_name_r2 $mf_ca_names_r2 {
    set mf_port_r2 [metamorphic_exact_sdram_port_r2 $mf_name_r2]
    set_output_delay -clock $mf_forward_r2 -max 1.540 $mf_port_r2
    set_output_delay -clock $mf_forward_r2 -min -1.300 $mf_port_r2
}
# No clocks, exceptions, multicycles, source or database mutation added here.
set_output_delay -clock [get_clocks SDRAM_CLK] -max 1.540 [mf145_port SDRAM_CKE]
set_output_delay -clock [get_clocks SDRAM_CLK] -min -1.300 [mf145_port SDRAM_CKE]

# Sole selected asynchronous SD-card input first stage only. Output/OE remains timed.
# R8 actual family: reg_524175 sd_cd_meta, FPGA_CLK1_50; IDs are revalidated per fit.
set mf145_sdmeta [get_registers {sd_cd_meta sd_cd_meta~DUPLICATE}]
if {[get_collection_size $mf145_sdmeta] < 1 || [get_collection_size $mf145_sdmeta] > 64} {error "SDCD firststage family missing/saturated"}
set mf145_sdseen {}; set mf145_sdprimary 0
foreach_in_collection id $mf145_sdmeta {
 set name [get_register_info -name $id]
 if {$name ne {sd_cd_meta} && $name ne {sd_cd_meta~DUPLICATE}} {error "Foreign SDCD firststage family member: $name"}
 if {[dict exists $mf145_sdseen $id] || [llength [get_register_info -clock_edges $id]] == 0} {error "Duplicate/unclocked SDCD firststage"}
 dict set mf145_sdseen $id 1
 if {$name eq {sd_cd_meta}} {incr mf145_sdprimary}
}
if {$mf145_sdprimary != 1} {error "Exact primary SDCD firststage required"}
set_false_path -from [mf145_port SDCD_SPDIF] -to $mf145_sdmeta
unset mf145_sdmeta mf145_sdseen mf145_sdprimary
# CHECK targets include native clock-network terms; postfit absolute pad-event proof
# remains required. Existing deb_*/btn_en/btn_up endpoint exceptions remain disclosed.
# derive_clock_uncertainty is deferred until update_timing_netlist; verify uncertainty
# on all three added pad clocks in the fresh native check, without changing jitter.

