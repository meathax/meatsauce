# Conditional DE10-Nano/ADV7513 board envelope; see evidence/board_io_contract.md.
# Must follow sys_top.sdc. Never replaces internal CDC constraints.
proc seicro_exact {label collection expected} {
    if {[get_collection_size $collection] != $expected} {error "$label: expected $expected endpoints"}
    return $collection
}
set sio_video [seicro_exact {HDMI video pads} [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 27]
set sio_pad [seicro_exact {HDMI clock pad} [get_ports HDMI_TX_CLK] 1]
set sio_scaler [seicro_exact {HDMI PLL clock} [get_clocks {*pll_hdmi*output_counter*divclk}] 1]
set sio_native [seicro_exact {game video clock} [get_clocks {*emu|pll*general?0?*PLL_OUTPUT_COUNTER*divclk}] 1]
set sio_scaler_source [seicro_exact {HDMI PLL source} [get_pins -compatibility_mode {*pll_hdmi*output_counter*divclk}] 1]
set sio_native_source [seicro_exact {game PLL source} [get_pins -compatibility_mode {*emu|pll*general?0?*PLL_OUTPUT_COUNTER*divclk}] 1]
# Data launches rising; altddio_out datain_h=0/datain_l=1 forwards inverted clock.
# Only impossible selected-output launch/capture combinations are suppressed.
# Removed inherited root/output cut: controls remain timed.
# Removed inherited root/output cut: controls remain timed.

# I2S is an enable-generated protocol, not a periodic divided fabric clock.
# Prove its source-edge gaps separately; bound pad propagation including clock insertion.
set sio_i2s [get_registers {*|i2s|sclk *|i2s|lrclk *|i2s|sdata}]
set sio_i2s_names {}
foreach_in_collection r $sio_i2s {lappend sio_i2s_names [get_register_info -name $r]}
proc c20_i2s_roles {names} {
 set canonical {}
 foreach n $names {
  regsub {~DUPLICATE(_[0-9]+)?$} $n {} n
  regsub {~_Duplicate_[0-9]+$} $n {} n
  lappend canonical $n
 }
 if {[lsort -unique $canonical] ne [lsort {{audio_out:audio_out|seicro_template_audio_out:sink|i2s:i2s|sclk} {audio_out:audio_out|seicro_template_audio_out:sink|i2s:i2s|lrclk} {audio_out:audio_out|seicro_template_audio_out:sink|i2s:i2s|sdata}}]} {error "Unreviewed I2S logical launch role"}
}
c20_i2s_roles $sio_i2s_names
puts "I2S_PHYSICAL_LAUNCHES [lsort $sio_i2s_names]"
set sio_audio [seicro_exact {ADV7513 I2S pads} [get_ports {HDMI_SCLK HDMI_LRCLK HDMI_I2S}] 3]
set_max_delay -from $sio_i2s -to $sio_audio 25.0
set_min_delay -from $sio_i2s -to $sio_audio 0.0

source selected_clocks.tcl
