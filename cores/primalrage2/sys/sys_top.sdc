# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk] 
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# --------------------------------------------------------------------------
# PR2 board-I/O timing ownership
#
# The PR2 image uses the HPS/DDRAM path for its disk image and leaves the
# generic MiSTer SD/USER expansion pins in their tri-stated or diagnostic
# roles.  The remaining low-speed inputs are asynchronous open-drain/status
# signals and are deliberately listed by port below so UCP cannot hide a new
# endpoint.  Video and I2S are synchronous and receive explicit output
# budgets against the clocks that drive their registered boundary logic.
# --------------------------------------------------------------------------
set pr2_async_inputs [get_ports -nowarn {
   HDMI_I2C_SDA HDMI_TX_INT IO_SDA SDCD_SPDIF
   USER_IO[3] USER_IO[4] USER_IO[6]
   altera_reserved_tdi altera_reserved_tms
}]
if {[get_collection_size $pr2_async_inputs] > 0} {
   set_false_path -from $pr2_async_inputs
}

set pr2_hdmi_clocks [get_clocks -nowarn {
   *|pll_hdmi|*|divclk
   *|pll|*|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
}]
set pr2_hdmi_data [get_ports -nowarn {
   HDMI_TX_DE HDMI_TX_D[*] HDMI_TX_HS HDMI_TX_VS
}]
if {[get_collection_size $pr2_hdmi_clocks] > 0 &&
    [get_collection_size $pr2_hdmi_data] > 0} {
   set_output_delay -clock $pr2_hdmi_clocks -max 2.0 $pr2_hdmi_data
   set_output_delay -clock $pr2_hdmi_clocks -min -1.0 $pr2_hdmi_data
}

# The generated clock is top-level pll_audio (no leading hierarchy bar).  Keep
# the exact name so TimeQuest applies the I2S output budget instead of leaving
# HDMI_I2S/LRCLK/MCLK/SCLK in the unconstrained-port report.
set pr2_audio_clocks [get_clocks -nowarn {
   pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
}]
set pr2_audio_ports [get_ports -nowarn {HDMI_MCLK HDMI_SCLK HDMI_LRCLK HDMI_I2S}]
if {[get_collection_size $pr2_audio_clocks] > 0 &&
    [get_collection_size $pr2_audio_ports] > 0} {
   set_output_delay -clock $pr2_audio_clocks -max 2.0 $pr2_audio_ports
   set_output_delay -clock $pr2_audio_clocks -min -1.0 $pr2_audio_ports
}

# cpuPaused is a clk1x mode bit carried with the level-held ch1_req handshake.
# The 3x ingress captures the whole request bundle only on clk3xIndex, after
# that handshake has made the qualifier stable.  Scope the CDC exception to
# this one qualifier/register pair; all address, data, request and response
# paths remain timed normally.
set pr2_pause_src [get_registers -nowarn {
   *|psx_top:ipsx_top|cpuPaused
}]
set pr2_pause_dst [get_registers -nowarn {
   *|sdram:sdram|ch1buf_dma
}]
if {[get_collection_size $pr2_pause_src] > 0 &&
    [get_collection_size $pr2_pause_dst] > 0} {
   set_false_path -from $pr2_pause_src -to $pr2_pause_dst
}

# These outputs are either open-drain/tri-state board services or are unused
# by the PR2 profile.  Their external timing is owned by the HPS/device, not
# by a PR2 synchronous data path; keep the exception port-scoped.
set_false_path -to [get_ports -nowarn {
   HDMI_TX_CLK HDMI_I2C_SCL HDMI_I2C_SDA
   IO_SCL IO_SDA LED[*]
   SDCD_SPDIF SDIO_CLK SDIO_CMD SDIO_DAT[*]
   SD_SPI_CS SD_SPI_CLK SD_SPI_MOSI
   USER_IO[*] altera_reserved_tdo
}]

# Decouple different clock groups (to simplify routing)
set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { hdmi_sck}] \
   -group [get_clocks { *|h2f_user0_clk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from [get_ports {SW[*]}]
set_false_path -to   {cfg[*]}
set_false_path -from {cfg[*]}
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
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {aflt_* acx* acy* areset* arc*}
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
