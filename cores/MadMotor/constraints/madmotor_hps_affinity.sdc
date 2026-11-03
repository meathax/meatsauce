# Mad Motor hard-HPS port mm_hps_clock affinity.
# AN796 section3.5.3: internal crossing is inside the hard interface.
# Preserve every mm_hps_associated-mm_hps_clock FPGA-facing setup/hold check.
# Native scope: docs/HPS_AFFINITY_TIMING_20261022.md.
# Source-derived hard interface mm_hps_family/mm_hps_clock inventory; diagnostic only.
set mm_hps_affinity_inventory {
    cmd_data_0 hps100 31
    cmd_data_1 core 28
    cmd_data_2 audio 32
    cmd_ready_0 hps100 1
    cmd_ready_1 core 1
    cmd_ready_2 audio 1
    cmd_valid_0 hps100 1
    cmd_valid_1 core 1
    cmd_valid_2 audio 1
    rd_data_0 hps100 64
    rd_data_1 hps100 64
    rd_data_2 core 64
    rd_data_3 audio 64
    rd_valid_1 hps100 1
    rd_valid_2 core 1
    rd_valid_3 audio 1
    wr_data_0 hps100 72
    wr_data_1 hps100 72
    wr_data_2 core 56
    wr_data_3 audio 8
}
set mm_hps_clocks [get_clocks *]
if {[get_collection_size $mm_hps_clocks] != 12} {error "Clock mm_hps_count differs from admitted matrix"}
set mm_hps_role_clocks [dict create core [get_clocks {*platform_pll*PLL_OUTPUT_COUNTER*divclk}] audio [get_clocks {pll_audio*PLL_OUTPUT_COUNTER*divclk}] hps100 [get_clocks {*|h2f_user0_clk}]]
foreach {mm_hps_role mm_hps_expected_period} {core 16.666666667 audio 40.682 hps100 10.0} {
    set mm_hps_c [dict get $mm_hps_role_clocks $mm_hps_role]
    if {[get_collection_size $mm_hps_c] != 1 || abs([get_clock_info -period $mm_hps_c]-$mm_hps_expected_period)>0.001} {error "Wrong $mm_hps_role mm_hps_clock"}
}
set mm_hps_family_pins [dict create]
foreach {mm_hps_family mm_hps_role mm_hps_count} $mm_hps_affinity_inventory {
    set mm_hps_nodes [get_pins -compatibility_mode "*|f2sdram|$mm_hps_family*"]
    set mm_hps_exact [list]
    foreach_in_collection mm_hps_node $mm_hps_nodes {
        set mm_hps_leaf [lindex [split [get_pin_info -name $mm_hps_node] |] end]
        regsub {\[[0-9]+\]$} $mm_hps_leaf "" mm_hps_leaf
        if {$mm_hps_leaf eq $mm_hps_family} {lappend mm_hps_exact $mm_hps_node}
    }
    if {[llength $mm_hps_exact] != $mm_hps_count} {error "Changed $mm_hps_family pin mm_hps_count"}
    # Convert the mm_hps_exact pin-name list back to a native collection.
    set mm_hps_names [list]
    foreach mm_hps_node $mm_hps_exact {lappend mm_hps_names [get_pin_info -name $mm_hps_node]}
    set mm_hps_pins [get_pins -compatibility_mode $mm_hps_names]
    if {[get_collection_size $mm_hps_pins] != $mm_hps_count} {error "Exact pin resolution changed"}
    dict set mm_hps_family_pins $mm_hps_family $mm_hps_pins
}
foreach {mm_hps_family mm_hps_role mm_hps_count} $mm_hps_affinity_inventory {
    set mm_hps_associated [dict get $mm_hps_role_clocks $mm_hps_role]
    set mm_hps_associated_name [get_clock_info -name $mm_hps_associated]
    foreach_in_collection mm_hps_clock $mm_hps_clocks {
        set mm_hps_clock_name [get_clock_info -name $mm_hps_clock]
        if {$mm_hps_clock_name ne $mm_hps_associated_name} {
            set mm_hps_pins [dict get $mm_hps_family_pins $mm_hps_family]
            set_false_path -from $mm_hps_clock -through $mm_hps_pins
            set_false_path -to $mm_hps_clock -through $mm_hps_pins
        }
    }
}
