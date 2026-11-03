# ADV7513 RevB AC specifications; conservative0.25ns board clock/data skew.
# https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf
# sys_top drives h=0/l=1 DDIO clock and positive-edge registered video data.
set jackal_hdmi_source [get_pins -compatibility_mode {hdmi_clk_sw|outclk}]
if {[get_collection_size $jackal_hdmi_source]!=1} {error {HDMI mux clock must resolve once}}
set jackal_native_master {}
set jackal_scaled_master {}
foreach_in_collection c [get_clocks *] {
 set n [get_clock_info -name $c]
 if {[string first {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk} $n]==0} {set jackal_native_master $n}
 if {[string first {pll_hdmi|pll_hdmi_inst|} $n]==0 && [string first {.output_counter|divclk} $n]>=0} {set jackal_scaled_master $n}
}
if {$jackal_native_master eq {} || $jackal_scaled_master eq {}} {error {Both HDMI modes must resolve}}
set jackal_video_outputs [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $jackal_video_outputs]!=27} {error {HDMI video must resolve27 outputs}}
foreach {master child} [list $jackal_native_master jackal_hdmi_native $jackal_scaled_master jackal_hdmi_scaled] {
 create_generated_clock -name $child -source $jackal_hdmi_source -master_clock $master -divide_by 1 -invert -add [get_ports HDMI_TX_CLK]
 set_output_delay -clock $child -max 2.05 -add_delay $jackal_video_outputs
 set_output_delay -clock $child -min -1.55 -add_delay $jackal_video_outputs
}
# Preserve both real same-mode checks; include forwarded children in the
# existing mutually-exclusive clock-mux modes, including native SDRAM.
set jackal_native_group [get_clocks [list $jackal_native_master jackal_hdmi_native jackal_sdram_clk]]
set jackal_scaled_group [get_clocks [list $jackal_scaled_master jackal_hdmi_scaled]]
if {[get_collection_size $jackal_native_group]!=3 || [get_collection_size $jackal_scaled_group]!=2} {error {HDMI mode groups incomplete}}
set_clock_groups -exclusive -group $jackal_native_group -group $jackal_scaled_group

# The actual16-bit I2S serializer uses a worst-case divide8 BCLK at96kHz.
# Register the divider clock before propagating its physical route to the pad.
set jackal_audio_master {}
foreach_in_collection c [get_clocks *] {
 set n [get_clock_info -name $c]
 if {[string first {pll_audio|} $n]==0 && [string first {divclk} $n]>=0} {set jackal_audio_master $n}
}
set jackal_audio_source [get_pins -compatibility_mode $jackal_audio_master]
set jackal_sclk_reg [get_registers {audio_out|i2s|sclk}]
set jackal_sclk_clk [get_pins -compatibility_mode {audio_out|i2s|sclk|clk}]
set jackal_sclk_q [get_pins -compatibility_mode {audio_out|i2s|sclk|q}]
foreach nodes [list $jackal_audio_source $jackal_sclk_reg $jackal_sclk_clk $jackal_sclk_q] {
 if {[get_collection_size $nodes]!=1} {error {I2S clock endpoint must resolve once}}
}
create_generated_clock -name jackal_audio_sclk_internal -source $jackal_sclk_clk -master_clock $jackal_audio_master -divide_by 8 $jackal_sclk_reg
create_generated_clock -name jackal_hdmi_i2s -source $jackal_sclk_q -master_clock jackal_audio_sclk_internal -divide_by 1 [get_ports HDMI_SCLK]
create_generated_clock -name jackal_hdmi_mclk -source $jackal_audio_source -master_clock $jackal_audio_master -divide_by 1 [get_ports HDMI_MCLK]
set jackal_audio_data [get_ports {HDMI_I2S HDMI_LRCLK}]
set_output_delay -clock jackal_hdmi_i2s -max 2.25 $jackal_audio_data
set_output_delay -clock jackal_hdmi_i2s -min -2.25 -add_delay $jackal_audio_data
set jackal_audio_registers [get_registers {audio_out|i2s|sdata audio_out|i2s|lrclk}]
if {[get_collection_size $jackal_audio_registers]!=2} {error {I2S data endpoints must resolve twice}}
# tests/timing/tb_audio.sv proves at least one MCLK before/after each BCLK
# rise, INCLUDING resets and rate switches. Reset drives BCLK low, never high.
# Setup keeps the ordinary C7->C8 one-MCLK relationship. Hold uses the first
# possible following launch C9->C8, rather than an unowned coincident C8 update.
# These are deliberate1/1 -start bounds across divide8, not an N/N-1 recipe.
set_multicycle_path -setup -start 1 -from $jackal_audio_registers -to $jackal_audio_data
set_multicycle_path -hold -start 1 -from $jackal_audio_registers -to $jackal_audio_data
derive_clock_uncertainty
