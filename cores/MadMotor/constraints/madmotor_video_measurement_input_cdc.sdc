# Input-level observers only, core60MHz -> independent HPS100MHz.
# Actual four-state test: video-measurement-input-20261023-04/receipt.json.
# Each level is >=many reference periods; the pixel/raster paths are unchanged.
set mm_measurement_first [get_registers {*|measurement_hs_sync[0] *|measurement_vs_sync[0] *|measurement_de_sync[0]}]
set mm_measurement_second [get_registers {*|measurement_hs_sync[1] *|measurement_vs_sync[1] *|measurement_de_sync[1]}]
if {[get_collection_size $mm_measurement_first]!=3 || [get_collection_size $mm_measurement_second]!=3} {error "Video measurement synchronizer inventory changed"}
if {abs([get_clock_info -period $mm_metrics_source_clock]-10.0)>0.001} {error "Video measurement reference clock changed"}
# Destination stage0 alone is asynchronous. Preserve every stage0->stage1,
# edge-history and measurement-counter path as ordinary 100MHz timing.
set_false_path -to $mm_measurement_first
