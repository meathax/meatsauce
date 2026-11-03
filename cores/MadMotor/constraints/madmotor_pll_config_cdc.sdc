# Acknowledged 38-bit custom command, source60 -> management50. Actual HPS
# ACK holds the source words until physical management acceptance. Two request
# samples precede destination capture (>40ns); returning ACK has two source
# stages. Proof: pll-config-cdc-20261024-06, sampler-cdc-20261024-03.
set mm_pll_source [add_to_collection [mm_cdc_bus {cfg_custom_p1*} cfg_custom_p1 6] [mm_cdc_bus {cfg_custom_p2*} cfg_custom_p2 32]]
set mm_pll_destination [add_to_collection [mm_cdc_bus {*pll_config_transfer|dst_address*} dst_address 6] [mm_cdc_bus {*pll_config_transfer|dst_data*} dst_data 32]]
set mm_pll_management_clock [get_clocks FPGA_CLK1_50]
if {[get_collection_size $mm_pll_management_clock]!=1 || abs([get_clock_info -period $mm_pll_management_clock]-20.000)>.001} {error "PLL management clock changed"}
set_max_delay -from $mm_pll_source -to $mm_pll_destination 20.000
set_min_delay -from $mm_pll_source -to $mm_pll_destination -16.666
foreach {source first} {
 {cfg_custom_t*} {*pll_config_transfer|request_meta}
 {*pll_config_transfer|acknowledge} {*pll_config_transfer|acknowledge_meta}
 {cfg_got*} {*pll_config_transfer|apply_meta}
 {*pll_config_transfer|ready} {*pll_config_transfer|ready_meta}
 {*pll_hdmi_adj|i_vss_delay*} {*pll_hdmi_adj|ivss_meta}
} {mm_cdc_toggle $source $first}
set mm_pll_output_level [get_registers {cfg_done* *ascal|o_vss}]
if {[get_collection_size $mm_pll_output_level]<2 || [get_collection_size $mm_pll_output_level]>8} {error "PLL output-level producers changed"}
set_false_path -from $mm_pll_output_level -to [mm_cdc_regs {*pll_hdmi_adj|ovss_meta} 1]
set mm_pll_first [get_registers {*pll_config_transfer|request_meta *pll_config_transfer|acknowledge_meta *pll_config_transfer|apply_meta *pll_config_transfer|ready_meta *pll_hdmi_adj|ivss_meta *pll_hdmi_adj|ovss_meta}]
set mm_pll_second [get_registers {*pll_config_transfer|request_sync *pll_config_transfer|acknowledge_sync *pll_config_transfer|apply_sync *pll_config_transfer|ready_sync *pll_hdmi_adj|ivss *pll_hdmi_adj|ovss}]
foreach nodes [list $mm_pll_first $mm_pll_second] {if {[get_collection_size $nodes]!=6} {error "PLL first/second-stage inventory changed"}}
set mm_pll_history_from [get_registers {*pll_config_transfer|apply_sync *pll_hdmi_adj|ivss *pll_hdmi_adj|ovss}]
set mm_pll_history_to [get_registers {*pll_config_transfer|apply_history *pll_hdmi_adj|ivss2 *pll_hdmi_adj|ovss2}]
foreach nodes [list $mm_pll_history_from $mm_pll_history_to] {if {[get_collection_size $nodes]!=3} {error "PLL event-history inventory changed"}}
set mm_pll_reset_first [mm_cdc_regs {*pll_config_reset_release|release_pipe[0]} 1]
set mm_pll_reset_second [mm_cdc_regs {*pll_config_reset_release|release_pipe[1]} 1]
