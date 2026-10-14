derive_pll_clocks

# core specific constraints

# Declared 32 MiB ISSI L CL2 profile: tAC<=6.5ns, tOH>=2.7ns;
# setup/hold 1.5/0.8ns. Board clock/data one-way flights provisionally 0..0.5ns.
# Explicit pin constraints; no multicycle or false-path exception for memory.
# Single master clock (outclk_0) clocks all core logic including DQ capture. The
# second PLL output (outclk_1, phase-shifted 7.805 ns) only feeds the forwarded
# SDRAM_CLK output cell and is not a register clock.
set cs_sdram_source [get_pins -compatibility_mode {*pll_inst*general[0]*divclk}]
set cs_sdram_fwd_source [get_pins -compatibility_mode {*pll_inst*general[1]*divclk}]
if {[get_collection_size $cs_sdram_source] != 1 || [get_collection_size $cs_sdram_fwd_source] != 1} {error "expected the core PLL outputs"}
create_generated_clock -name cs_sdram_clk -source $cs_sdram_fwd_source -divide_by 1 [get_ports {SDRAM_CLK}]
set_input_delay -clock cs_sdram_clk -max 7.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock cs_sdram_clk -min 2.7 [get_ports {SDRAM_DQ[*]}]

# DQ capture edge (registers on the master clock). SDRAM_CLK leaves the pin ~4.4 ns later than
# the master clock reaches the input registers (output-DDIO clock routing) plus the 7.805 ns
# PLL shift, and CL2 data follows that pin edge by up to
# tAC 6.5 ns (+ board/pad terms in the 7.5 ns input delay), so a one-period single-edge
# relationship is physically unreachable. The capture register samples the NEXT capture
# edge: -setup 2, scoped to the 16 DQ pins -> 16 capture registers. No -hold option is
# given, so STA keeps the strict hold edge one period before the setup edge (data from the
# new beat may not arrive before the previous capture). The capture phase (pll_0002
# phase_shift1) is placed to balance setup/hold margin across all four corners.
set cs_dq_cap [get_registers {*cs_sdram_backend:sdram|sampled_dq[*]}]
if {[get_collection_size $cs_dq_cap] != 16} {error "expected 16 SDRAM DQ capture registers"}
set_multicycle_path -setup 2 -from [get_ports {SDRAM_DQ[*]}] -to $cs_dq_cap
set cs_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE}]
set_output_delay -clock cs_sdram_clk -max 2.0 $cs_sdram_outputs
set_output_delay -clock cs_sdram_clk -min -1.3 $cs_sdram_outputs

# HDMI video timing for the upstream Main_MiSTer default 0xBA=0x60 (zero delay).
# ADV7513 Rev B tSU/tH=1.8/1.3 ns; provisional board clock/data flights 0..0.5 ns.
# Other HPS register settings and dynamically reconfigured PLL frequencies require
# their own qualification. Full programmable-range diagnostic remains preserved.
set cs_hdmi_pins [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $cs_hdmi_pins] != 27} {error "expected 27 HDMI video pins"}
set cs_hdmi_mux [get_pins -compatibility_mode {hdmi_clk_sw|outclk}]
set cs_hdmi_scaled_source [get_pins -compatibility_mode {*pll_hdmi*counter[0].output_counter|divclk}]
if {[get_collection_size $cs_hdmi_mux] != 1 || [get_collection_size $cs_hdmi_scaled_source] != 1} {error "expected HDMI mux and scaled PLL output"}
foreach {cs_mode cs_source} [list native $cs_sdram_source scaled $cs_hdmi_scaled_source] {
    foreach_in_collection cs_pin $cs_source {set cs_master [get_node_info -name $cs_pin]}
    create_generated_clock -name cs_hdmi_mux_$cs_mode -source $cs_source -master_clock $cs_master -divide_by 1 -add $cs_hdmi_mux
    # Actual forwarded clock is high=0/low=1: receiver rises on source falling edge.
    create_generated_clock -name cs_hdmi_$cs_mode -source $cs_hdmi_mux -master_clock cs_hdmi_mux_$cs_mode -invert -add [get_ports {HDMI_TX_CLK}]
    set_output_delay -clock cs_hdmi_$cs_mode -max 2.3 -add_delay $cs_hdmi_pins
    set_output_delay -clock cs_hdmi_$cs_mode -min -1.8 -add_delay $cs_hdmi_pins
}
# Extend the framework's existing core/HDMI clock groups to these mode aliases.
# Only one mux branch drives the pin registers. This does not qualify CDC logic.
set_clock_groups -logically_exclusive \
    -group [get_clocks {*emu|pll* cs_sdram_clk cs_hdmi_mux_native cs_hdmi_native}] \
    -group [get_clocks {*pll_hdmi* cs_hdmi_mux_scaled cs_hdmi_scaled}]

# Qualified one-bit asynchronous timing inputs into the HPS frame counters.
# Cut only the four first-stage D inputs; all second-stage/counter paths remain timed.
set cs_calc_meta [get_registers {*|hps_io|video_calc|calc_sync_meta[*]}]
if {[get_collection_size $cs_calc_meta] != 4} {error "expected four video counter CDC first stages"}
set_false_path -to $cs_calc_meta

# Slow, asynchronous framework I/O with no synchronous interface to constrain (I2C, SD card/
# SDIO/analog-over-SDIO, SPDIF/card-detect, HDMI audio I2S at >=100 ns bit period, user/LED
# pins, ADV7513 interrupt). Same treatment as the framework's own LED_/VGA_/AUDIO_ cuts.
# Memory, HDMI video and all core paths remain timed; nothing here touches them.
set_false_path -from [get_ports {HDMI_TX_INT IO_SDA HDMI_I2C_SDA SDCD_SPDIF SDIO_CMD SDIO_DAT[*] USER_IO[*]}]
set_false_path -to [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA HDMI_I2S HDMI_LRCLK HDMI_MCLK HDMI_SCLK IO_SCL IO_SDA LED[*] SDCD_SPDIF SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS USER_IO[*]}]

# Include all explicitly created forwarded clocks in uncertainty derivation.
derive_clock_uncertainty
