# Conditional DE10-Nano ADV7513 receiver envelope. The source-bound
# sys_top.v launches 27 video pads on posedge hdmi_tx_clk; hdmiclk_ddr
# forwards its inverse (datain_h=0, datain_l=1). Both mux modes are retained.
# ADV7513 Rev.B Table 1: tVSU=1.8 ns, tVHLD=1.3 ns. Assumed board
# clock/data skew is +/-0.5 ns, unmeasured; no receiver phase override.
proc midres_exact {label objects count} {
    if {[get_collection_size $objects] != $count} {error "$label cardinality differs from $count"}
    return $objects
}
set mv_pads [midres_exact {HDMI video pads} [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 27]
set mv_clkpad [midres_exact {HDMI forwarded clock} [get_ports HDMI_TX_CLK] 1]
set mv_scaler [midres_exact {scaler clock} [get_clocks {*pll_hdmi*output_counter*divclk}] 1]
set mv_native [midres_exact {native video clock} [get_clocks {*emu|pll*general?0?*PLL_OUTPUT_COUNTER*divclk}] 1]
set mv_sref [midres_exact {scaler source pin} [get_pins -compatibility_mode {*pll_hdmi*output_counter*divclk}] 1]
set mv_nref [midres_exact {native source pin} [get_pins -compatibility_mode {*emu|pll*general?0?*PLL_OUTPUT_COUNTER*divclk}] 1]
create_generated_clock -name midres_hdmi_scaler -source $mv_sref -master_clock $mv_scaler -divide_by 1 -invert $mv_clkpad
create_generated_clock -name midres_hdmi_native -source $mv_nref -master_clock $mv_native -divide_by 1 -invert -add $mv_clkpad
# Impossible selected-mux launch/capture combinations only; no internal CDC cut.
set_false_path -from $mv_native -to [get_clocks midres_hdmi_scaler]
set_false_path -from $mv_scaler -to [get_clocks midres_hdmi_native]
foreach mv_clock {midres_hdmi_scaler midres_hdmi_native} {
    set_output_delay -clock $mv_clock -max 2.3 -add_delay $mv_pads
    set_output_delay -clock $mv_clock -min -1.8 -add_delay $mv_pads
}
# I2S has CE-generated SCLK, not a fictitious periodic fabric clock. Target
# serializer/producer proof bounds active-stream source edges at >=40.682ns
# setup and >=122.046ns hold, including rate changes/stalls. With pad0..25ns
# and +/-0.5ns skew this exceeds ADV7513 2ns setup/hold at either SCLK edge.
set mv_audio_ff [midres_exact {I2S launch registers} [get_registers {*|i2s|sclk *|i2s|lrclk *|i2s|sdata}] 3]
set mv_audio_pads [midres_exact {ADV7513 I2S pads} [get_ports {HDMI_SCLK HDMI_LRCLK HDMI_I2S}] 3]
set_max_delay -from $mv_audio_ff -to $mv_audio_pads 25.0
set_min_delay -from $mv_audio_ff -to $mv_audio_pads 0.0
