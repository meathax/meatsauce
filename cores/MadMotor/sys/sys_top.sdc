# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk] 
create_clock -period "100.0 MHz" [get_pins -compatibility_mode spi|sclk_out] -name spi_sck
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# Preserve every inherited inter-group pair except HDMI PLL <-> Avalon.
# Those clocks operate simultaneously in the scaler, so their transfers must
# remain visible. Exact mailbox constraints require separate transfer proof.
# Empty inherited collections are skipped to avoid single-group commands
# accidentally excluding a group from every other clock in the design.
set mm_legacy_clock_groups [list \
   [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   [get_clocks { spi_sck}] \
   [get_clocks { hdmi_sck}] \
   [get_clocks { *|h2f_user0_clk}] \
   [get_clocks { FPGA_CLK1_50 }] \
   [get_clocks { FPGA_CLK2_50 }] \
   [get_clocks { FPGA_CLK3_50 }]]
if {[get_collection_size [lindex $mm_legacy_clock_groups 1]]!=1 ||
    [get_collection_size [lindex $mm_legacy_clock_groups 5]]!=1} {
    error "Exact simultaneous scaler HDMI/Avalon roots required"
}
for {set mm_clock_a 0} {$mm_clock_a<[llength $mm_legacy_clock_groups]} {incr mm_clock_a} {
    for {set mm_clock_b [expr {$mm_clock_a+1}]} {$mm_clock_b<[llength $mm_legacy_clock_groups]} {incr mm_clock_b} {
        if {$mm_clock_a==1 && $mm_clock_b==5} {continue}
        set mm_group_a [lindex $mm_legacy_clock_groups $mm_clock_a]
        set mm_group_b [lindex $mm_legacy_clock_groups $mm_clock_b]
        if {[get_collection_size $mm_group_a]>0 && [get_collection_size $mm_group_b]>0} {
            set_clock_groups -exclusive -group $mm_group_a -group $mm_group_b
        }
    }
}

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from {get_ports {SW[*]}}
set_false_path -to   {cfg[*]}
# Preserve the inherited cfg consumer scope, except the new same-root snapshot.
set mm_cfg_snapshot [get_registers {*audio_config_transfer|held_payload* *video_config_transfer|held_payload*}]
if {[get_collection_size $mm_cfg_snapshot]<163} {error "Audio configuration snapshot missing"}
set_false_path -from {cfg[*]} -to [remove_from_collection [get_keepers *] $mm_cfg_snapshot]
set_false_path -from {VSET[*]}
set_false_path -to   {wcalc[*] hcalc[*]}
set_false_path -to   {hdmi_width[*] hdmi_height[*]}
set_false_path -to   {deb_* btn_en btn_up}

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*} -to [remove_from_collection [get_keepers *] $mm_cfg_snapshot]
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]} -to [remove_from_collection [get_keepers *] $mm_cfg_snapshot]
set_false_path -to   {LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {scaler_flt[*] led_overtake[*] led_state[*]} -to [remove_from_collection [get_keepers *] $mm_cfg_snapshot]
# Audio controls now enter a same-root held snapshot; retain full-rate checks.
set_false_path -from {arc*}
set_false_path -from {arx* ary*}
set_false_path -from {vs_line*}
set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}

set_false_path -from {ascal|o_ihsize*}
set_false_path -from {ascal|o_ivsize*}
set_false_path -from {ascal|o_format*}
set_false_path -from {ascal|o_hdown}
set_false_path -from {ascal|o_vdown}
set_false_path -from {ascal|o_hmin* ascal|o_hmax* ascal|o_vmin* ascal|o_vmax* ascal|o_vrrmax* ascal|o_vrr}
set_false_path -from {ascal|o_hdisp* ascal|o_vdisp*}
set_false_path -from {ascal|o_htotal* ascal|o_vtotal*}
set_false_path -from {ascal|o_hsstart* ascal|o_vsstart* ascal|o_hsend* ascal|o_vsend*}
set_false_path -from {ascal|o_hsize* ascal|o_vsize*}

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}
