## Leland / Asylum timing constraints.
derive_pll_clocks
derive_clock_uncertainty

## Standard MiSTer reference profile: DE10-Nano Rev C + XS-DS v3.0 128MB,
## with the onboard ADV7513 HDMI transmitter. The standard 128MB XS-DS module
## uses two Alliance Memory AS4C32M16SB-7TCN devices. Use the slow -7 grade
## AC timing limits (Alliance Memory Rev. 1.2, March 2020, Table 16):
## CL2 tAC(max)=6.0ns, tOH(min)=2.5ns (open output), tIS/tDS=1.5ns,
## and tIH/tDH=0.8ns. These CL2 limits are also conservative if the controller
## uses CL3.
## The user authorized a standard-reference timing model without board-route
## measurements. The external bounds below assume each one-way FPGA/connector/
## module leg is 0..1.0ns. This is an explicit design budget, not measured PCB
## data. A passing report qualifies only this named profile conditional on every
## route staying inside that budget; it does not establish all-module or measured
## hardware qualification. Read-DQ input max is the absolute round trip
## dClkFwd,max + tAC,max + dDQRet,max, not a clock/data differential.
## CKE is included with command/address outputs; the SDRAM datasheet samples
## it on CLK and specifies the same tIS/tIH setup/hold family.
##
## The memory clock is forwarded non-inverted by altddio_out (data_h=1,
## data_l=0) from PLL output 1. Source it from the actual PLL output so
## TimeQuest retains the fitted 5472ps phase.
create_generated_clock -name sdram_fwd_clk \
    -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 [get_ports {SDRAM_CLK}]

## Command and write-data transfers use the actual forwarded/core clock edges (no
## exceptions). Read data is registered by its own PLL output (clk_cap, PLL output 2,
## phase 7143ps) in the DQ pad register. Edge proof: with the 0..1ns one-way budget,
## tAC(max)=6.0ns, tOH(min)=2.5ns and the fitted clock insertions, the default pairing
## (forwarded launch edge -> next core-rate edge) fails the read setup at every corner
## and the next beat arrives before the following edge; the stable data window sits
## between those edges. clk_cap places its edge in that window, one capture-clock period
## after the default pairing. The controller loads this pad register one core edge later
## (READ_CAP_EXTRA=1), so it captures the same READ beat as before. The exception applies
## only from the forwarded clock to the DQ pad registers. There is deliberately NO hold
## exception: with setup 2 the default hold edge pairs the NEXT beat's launch with the
## capture edge of this beat, which is exactly the check that matters (a hold -end 1
## would move it back a full period and hide it). Fitted slacks: setup +2.88..+5.91 ns,
## hold +3.75..+5.80 ns over all 8 corners (scripts/sdram_capture_window.tcl).
set_multicycle_path -setup -end 2 -from [get_clocks sdram_fwd_clk] -to [get_registers {*sd_dq_q[*]}]
set_output_delay -clock sdram_fwd_clk -max  2.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE SDRAM_DQML SDRAM_DQMH SDRAM_DQ[*]}]
set_output_delay -clock sdram_fwd_clk -min -1.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE SDRAM_DQML SDRAM_DQMH SDRAM_DQ[*]}]
set_input_delay  -clock sdram_fwd_clk -max  8.0 [get_ports {SDRAM_DQ[*]}]
## Earliest DQ return is the SDRAM's tOH(min) plus minimum clock/data routes;
## tIS/tDS applies to FPGA-driven inputs and must not be reused for read DQ.
set_input_delay  -clock sdram_fwd_clk -min  2.5 [get_ports {SDRAM_DQ[*]}]

## DE10-Nano HDMI transmitter (ADV7513) reference-path timing.
## sys_top registers HDMI_TX_D/DE/HS/VS on posedge hdmi_tx_clk. The
## altddio_out drives HDMI_TX_CLK inverted (datain_h=0, datain_l=1), so the
## ADV7513's rising-edge capture is the falling edge of hdmi_tx_clk. Define
## the actual inverted forwarded clock at the output port for both runtime
## mux sources. This lets TimeQuest use the receiver capture edge and include
## the fitted HDMI_TX_CLK D5 output delay in the clock path.
## ADV7513 Rev.B specifies 1.8ns video setup and 1.3ns hold. For the standard
## DE10-Nano onboard FPGA-to-ADV7513 link, use a +/-0.5ns data-to-clock
## differential route-skew budget. This bounds relative lane/clock routing; it
## is a standard-board design assumption, not extracted PCB geometry.
## output max = 1.8 + 0.5 = 2.3ns; output min = -1.3 - 0.5 = -1.8ns.
## A pass qualifies this profile only when HDMI lane-to-clock skew stays within
## that +/-0.5ns budget. SDRAM keeps its separately documented 0..1ns legs.
## HDMI audio timing at the ADV7513. HDMI_SCLK and all I2S state are generated
## from the 24.576MHz HDMI_MCLK domain. The output SCLK divider is CE-driven,
## so its phase can move with reset/stall/rate transitions. Enumerate every
## possible source-rising-edge phase for both steady rates instead of guessing
## one startup phase. SCLK transitions only on clk_audio rising edges; the
## I2S data/LRCLK output registers below launch on falling edges. Therefore
## the MCLK-edge checks below cover the source-edge phase union. The forwarded
## SCLK checks added after its clock definitions also include the actual SCLK
## register and pad capture latency for every phase, reset/stall and rate.
## ADV7513 tSU/tH are 2ns; the 0..1ns per-leg
## output-path budget gives conservative max/min external delays of +3/-3ns.
## Quartus 17 get_clocks filters clock names, not output-port names. Enumerate
## its clock objects and match get_clock_info -name against the exact identities
## emitted by derive_pll_clocks; this also avoids treating one clock object as
## a collection. The set/count guards reject unexpected PLL naming or pruning.
set hdmi_tx_capture_count 0
set hdmi_audio_mclk_count 0
foreach_in_collection hdmi_clock [get_clocks] {
    set hdmi_clock_name [get_clock_info -name $hdmi_clock]
    if {$hdmi_clock_name eq {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} || \
        $hdmi_clock_name eq {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}} {
        if {$hdmi_clock_name eq {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}} {
            create_generated_clock -add -name hdmi_tx_fwd_direct \
                -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
                -divide_by 1 -invert [get_ports {HDMI_TX_CLK}]
        } else {
            create_generated_clock -add -name hdmi_tx_fwd_scaler \
                -source [get_pins {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
                -divide_by 1 -invert [get_ports {HDMI_TX_CLK}]
        }
        incr hdmi_tx_capture_count
    }
    if {$hdmi_clock_name eq {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}} {
        incr hdmi_audio_mclk_count
        set_output_delay -clock $hdmi_clock -max  3.0 [get_ports {HDMI_I2S HDMI_LRCLK}]
        set_output_delay -clock $hdmi_clock -min -3.0 [get_ports {HDMI_I2S HDMI_LRCLK}]
    }
}
if {$hdmi_tx_capture_count != 2} {
    error "Expected two exact propagated capture clocks for HDMI_TX_CLK data"
}
if {[get_collection_size [get_clocks hdmi_tx_fwd_direct]] != 1 || \
    [get_collection_size [get_clocks hdmi_tx_fwd_scaler]] != 1} {
    error "Failed to define both inverted HDMI_TX_CLK capture clocks"
}
## hdmi_tx_clk is one Cyclone V clock-select output used by both the pixel
## registers and forwarded-clock DDIO. Pair each source parent with its own
## inverted output child; opposite-mode parent/child transfers cannot occur.
set hdmi_tx_direct_mode_clocks [add_to_collection \
    [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_clocks hdmi_tx_fwd_direct]]
set hdmi_tx_scaler_mode_clocks [add_to_collection \
    [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    [get_clocks hdmi_tx_fwd_scaler]]
if {[get_collection_size $hdmi_tx_direct_mode_clocks] != 2 || \
    [get_collection_size $hdmi_tx_scaler_mode_clocks] != 2} {
    error "Expected each HDMI mode clock group to contain its parent and forwarded child"
}
set_clock_groups -exclusive \
    -group $hdmi_tx_direct_mode_clocks \
    -group $hdmi_tx_scaler_mode_clocks
set_output_delay -clock hdmi_tx_fwd_direct -max  2.3 [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_output_delay -clock hdmi_tx_fwd_direct -min -1.8 [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_output_delay -add_delay -clock hdmi_tx_fwd_scaler -max  2.3 [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
set_output_delay -add_delay -clock hdmi_tx_fwd_scaler -min -1.8 [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {$hdmi_audio_mclk_count != 1} {
    error "Expected exactly one HDMI audio PLL clock for HDMI_MCLK data"
}
set hdmi_audio_mclk_port [get_ports {HDMI_MCLK}]
set hdmi_sclk_port [get_ports {HDMI_SCLK}]
set hdmi_audio_root_pin [get_pins {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set hdmi_sclk_register [get_registers {audio_out:audio_out|i2s:i2s|sclk}]
if {[get_collection_size $hdmi_audio_root_pin] != 1 || \
    [get_collection_size $hdmi_sclk_register] != 1 || \
    [get_collection_size $hdmi_audio_mclk_port] != 1 || \
    [get_collection_size $hdmi_sclk_port] != 1} {
    error "Expected exact HDMI audio root, divider register and forwarded ports"
}
create_generated_clock -name hdmi_audio_mclk_fwd \
    -source $hdmi_audio_root_pin -divide_by 1 $hdmi_audio_mclk_port
## Anchor the divider on its real fitted register, then propagate that clock
## to the pin. A pad-only clock sourced from HDMI_MCLK leaves the internal
## divider unclocked in check_timing and loses the routed source lineage.
## These steady-rate waveforms describe the clock output; data capture remains
## constrained against EVERY parent rising edge above, including transitions.
set hdmi_sclk_phase_clocks {}
foreach {rate period_cycles half_cycles} {48k 16 8 96k 8 4} {
    for {set phase 0} {$phase < $period_cycles} {incr phase} {
        set rise_edge [expr {1 + 2 * $phase}]
        set fall_edge [expr {$rise_edge + 2 * $half_cycles}]
        set next_rise_edge [expr {$rise_edge + 4 * $half_cycles}]
        set hdmi_sclk_name "hdmi_sclk_${rate}_phase${phase}"
        set hdmi_sclk_internal_name "${hdmi_sclk_name}_internal"
        if {[llength $hdmi_sclk_phase_clocks] == 0} {
            create_generated_clock -name $hdmi_sclk_internal_name \
                -source $hdmi_audio_root_pin \
                -edges [list $rise_edge $fall_edge $next_rise_edge] $hdmi_sclk_register
        } else {
            create_generated_clock -add -name $hdmi_sclk_internal_name \
                -source $hdmi_audio_root_pin \
                -edges [list $rise_edge $fall_edge $next_rise_edge] $hdmi_sclk_register
        }
        create_generated_clock -add -name $hdmi_sclk_name \
            -master_clock $hdmi_sclk_internal_name -source $hdmi_sclk_register \
            -divide_by 1 $hdmi_sclk_port
        lappend hdmi_sclk_phase_clocks $hdmi_sclk_name
    }
}
foreach hdmi_sclk_name $hdmi_sclk_phase_clocks {
    if {[get_collection_size [get_clocks $hdmi_sclk_name]] != 1} {
        error "Failed to define generated HDMI SCLK phase $hdmi_sclk_name"
    }
    # The receiver captures relative to the physical forwarded SCLK pin.
    # Retain the parent-edge checks too; these add the real capture latency.
    set_output_delay -add_delay -clock [get_clocks $hdmi_sclk_name] -max 3.0 [get_ports {HDMI_I2S HDMI_LRCLK}]
    set_output_delay -add_delay -clock [get_clocks $hdmi_sclk_name] -min -3.0 [get_ports {HDMI_I2S HDMI_LRCLK}]
}
## Platform-owned HPS/ADV7513 control pins. The I2C pair is driven/captured by
## the Cyclone V HPS peripheral-I2C hard interface; HDMI_TX_INT enters the HPS
## GP hard interface. These exact boundaries have no FPGA fabric receiver clock.
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT}]
set_false_path -to   [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA}]

## The qualified reference profile is DE10-Nano + onboard HDMI + XS-DS v3.0.
## It excludes the optional I/O/AV board, GPIO expander, user-port devices, and
## secondary-SD peripherals. Waive only their exact expansion-connector pins;
## an assembly with any such add-on requires its own receiver/input timing model.
set_false_path -from [get_ports {IO_SDA SDCD_SPDIF SD_SPI_MISO SDIO_CMD SDIO_DAT[*] USER_IO[*]}]
set_false_path -to   [get_ports {IO_SCL IO_SDA SDCD_SPDIF SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS SD_SPI_CLK SD_SPI_MOSI USER_IO[*]}]

## These two outputs are board status indicators. They have no external
## synchronous receiver; exempt only the physical indicator endpoints.
set_false_path -to [get_ports {LED[2] LED[6]}]
