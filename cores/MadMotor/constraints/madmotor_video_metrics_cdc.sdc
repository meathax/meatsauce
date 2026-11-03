# Exact held128bit measurement snapshot,100MHz -> core60MHz.
# Actual four-state proof: evidence/sim/video-metrics-20261023-07/receipt.json.
# Earliest capture >=2Tcore, replacement >=2T100 after capture. Budgets include
# Q17 clock latency and leave one protocol period on each side. No clock cut.
set mm_metrics_source_clock [get_clocks {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}]
if {[get_collection_size $mm_metrics_source_clock]!=1} {error "Metrics source clock inventory changed"}
set mm_metrics_src_period [get_clock_info -period $mm_metrics_source_clock]
set mm_metrics_dst_period [get_clock_info -period $mm_cdc_core]
if {abs($mm_metrics_src_period-10.0)>0.001 || abs($mm_metrics_dst_period-1000.0/60)>0.001} {error "Metrics clock profile changed"}
set mm_metrics_held [mm_cdc_bus {*|metrics_transfer|held_payload[*]} held_payload 128]
set mm_metrics_dst [mm_cdc_bus {*|metrics_transfer|dst_data[*]} dst_data 128]
set_max_delay -from $mm_metrics_held -to $mm_metrics_dst $mm_metrics_dst_period
set_min_delay -from $mm_metrics_held -to $mm_metrics_dst [expr {-$mm_metrics_src_period}]
mm_cdc_toggle {*|metrics_transfer|request_toggle*} {*|metrics_transfer|request_sync[0]}
mm_cdc_toggle {*|metrics_transfer|acknowledge_toggle*} {*|metrics_transfer|acknowledge_sync[0]}
# All measurement->held captures, interstage timing and local power-up-reset
# recovery/removal remain timed. No new reset-control exception is required.
