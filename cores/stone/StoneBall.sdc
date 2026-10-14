derive_pll_clocks
derive_clock_uncertainty

# Match this project's PLL hierarchy when applying the MiSTer template's
# exclusive clock groups. sys_top.sdc expects a generated pll_inst wrapper;
# stone_pll directly instantiates altera_pll instead. Keep all four Stone
# clocks together so fabric/video/SDRAM timing remains analyzed internally.
set stone_clocks [get_clocks {emu|pll|pll|*|divclk}]
if {[get_collection_size $stone_clocks] != 4} {
    error "Expected four Stone Ball PLL output clocks"
}

# The SDRAM clock is forwarded from the phase-shifted 100 MHz PLL output.
# Constrain the external memory round trip at the physical clock pin. These
# board-level budgets follow the MiSTer SDRAM interface constraints used by
# the local MCR68 reference core.
set sdram_shift_clk [get_clocks {emu|pll|pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set sdram_clk_port [get_ports SDRAM_CLK]
if {[get_collection_size $sdram_shift_clk] != 1 ||
    [get_collection_size $sdram_clk_port] != 1} {
    error "Stone Ball SDRAM constraints could not resolve the shifted PLL clock and SDRAM_CLK"
}
create_generated_clock -name STONE_SDRAM_PIN \
    -source [get_clock_info -targets $sdram_shift_clk] \
    -divide_by 1 $sdram_clk_port
set sdram_pin_clk [get_clocks STONE_SDRAM_PIN]
if {[get_collection_size $sdram_pin_clk] != 1} {
    error "Stone Ball SDRAM forwarded clock was not created"
}
set stone_clocks [add_to_collection $stone_clocks $sdram_pin_clk]
set_input_delay -clock $sdram_pin_clk -max 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock $sdram_pin_clk -min 3.2 [get_ports {SDRAM_DQ[*]}]
set sdram_read_data_regs [get_registers {*|stone_sdram_bridge:memory|sdram_stock:ctl|data[*]}]
if {[get_collection_size $sdram_read_data_regs] != 16} {
    error "Stone Ball SDRAM return-data registers did not resolve"
}
# CAS-2 returns a word after the read command, and the controller captures it
# on the second rising fabric edge after the forwarded launch edge, using a
# registered valid pulse. Model that cycle-later sample explicitly. There is
# deliberately no paired hold exception: the default hold edge, one cycle
# before the setup edge, checks the real end of the read window (the next
# forwarded edge plus the 3.2 ns minimum output hold). A -hold 1 exception
# would move that check a whole cycle earlier and hide a window violation.
set_multicycle_path -setup -end 2 -from [get_ports {SDRAM_DQ[*]}] -to $sdram_read_data_regs
set sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                              SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock $sdram_pin_clk -max 1.5 $sdram_outputs
set_output_delay -clock $sdram_pin_clk -min -0.8 $sdram_outputs

# HDMI_TX_CLK is source-synchronous and selected between the core's video
# clock and MiSTer's fixed 148.5 MHz scaler clock. The DDR clock output is
# inverted relative to either source. Apply receiver setup/hold budgets to
# each legal source as the platform reference core does.
set core_tx_clk [get_clocks {emu|pll|pll|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]
set scaler_tx_clk [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set tx_clock_port [get_ports HDMI_TX_CLK]
if {[get_collection_size $core_tx_clk] != 1 ||
    [get_collection_size $scaler_tx_clk] != 1 ||
    [get_collection_size $tx_clock_port] != 1} {
    error "Stone Ball HDMI constraints could not resolve both source clocks and HDMI_TX_CLK"
}
create_generated_clock -name STONE_HDMI_CORE \
    -source [get_clock_info -targets $core_tx_clk] \
    -master_clock $core_tx_clk -divide_by 1 -invert $tx_clock_port
create_generated_clock -name STONE_HDMI_SCALER \
    -source [get_clock_info -targets $scaler_tx_clk] \
    -master_clock $scaler_tx_clk -divide_by 1 -invert -add $tx_clock_port
set core_tx_pin_clk [get_clocks STONE_HDMI_CORE]
set scaler_tx_pin_clk [get_clocks STONE_HDMI_SCALER]
if {[get_collection_size $core_tx_pin_clk] != 1 ||
    [get_collection_size $scaler_tx_pin_clk] != 1} {
    error "Stone Ball HDMI forwarded clocks were not created"
}
set stone_clocks [add_to_collection $stone_clocks $core_tx_pin_clk]
set hdmi_scaler_clocks [add_to_collection [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*|divclk}] $scaler_tx_pin_clk]
set hdmi_tx_data [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $hdmi_tx_data] != 27} {
    error "Stone Ball HDMI constraints require 24 data, DE, HS and VS outputs"
}
set_output_delay -clock STONE_HDMI_CORE -max 2.0 $hdmi_tx_data
set_output_delay -clock STONE_HDMI_CORE -min -1.8 $hdmi_tx_data
set_output_delay -clock STONE_HDMI_SCALER -max 2.0 -add_delay $hdmi_tx_data
set_output_delay -clock STONE_HDMI_SCALER -min -1.8 -add_delay $hdmi_tx_data

# The HPS audio serializer is source-synchronous to the dedicated audio PLL.
set audio_output_clk [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $audio_output_clk] != 1} {
    error "Stone Ball audio constraints could not resolve the audio PLL output"
}
set_output_delay -clock $audio_output_clk -max 2.0 [get_ports {HDMI_I2S HDMI_SCLK HDMI_LRCLK HDMI_MCLK}]
set_output_delay -clock $audio_output_clk -min -1.0 [get_ports {HDMI_I2S HDMI_SCLK HDMI_LRCLK HDMI_MCLK}]

# These pins are asynchronous management/control or optional SD/user I/O.
# Their protocols have no synchronous timing contract in this core.
set_false_path -from [get_ports {HDMI_TX_INT HDMI_I2C_SDA IO_SDA SDCD_SPDIF}]
set_false_path -to [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA IO_SCL IO_SDA AUDIO_L AUDIO_R AUDIO_SPDIF SDCD_SPDIF SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CLK SD_SPI_CS SD_SPI_MOSI LED[*] USER_IO[*]}]

# Keep the core's 100 MHz fabric, phase-shifted SDRAM clock, video clock and
# forwarded source clocks related. The HDMI scaler is a mutually exclusive
# source selected by the platform clock mux.
set_clock_groups -exclusive \
    -group $stone_clocks \
    -group $hdmi_scaler_clocks \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# TMS instruction decode. instr_word_q loads only on the FETCH acknowledge
# that enters CORE_DECODE; CORE_DECODE always moves to CORE_DECODE_WAIT, and
# the decode record and class flags load only in CORE_DECODE_WAIT. The
# combinational decoder (input: instr_word_q only) therefore always has two
# complete fabric cycles, as the core's decode comment states.
set tms_instr_word [get_registers {*|u_core|instr_word_q[*]}]
set tms_decode_regs [get_registers {*|u_core|decoded.* *|u_core|iclass_mem_q[*] *|u_core|iclass_pix_q[*] *|u_core|is_fill_q *|u_core|fill_is_xy_q *|u_core|is_pblt_q *|u_core|is_drav_q *|u_core|is_line_q *|u_core|is_mv_store_q *|u_core|is_mv_load_q *|u_core|is_mmtm_decode_q *|u_core|pixt_store_decode_q *|u_core|pixt_xy_store_decode_q *|u_core|trap_skip_push}]
if {[get_collection_size $tms_instr_word] == 0 || [get_collection_size $tms_decode_regs] < 8} {
    error "Stone Ball TMS decode multicycle registers did not resolve"
}
set_multicycle_path -setup -end 2 -from $tms_instr_word -to $tms_decode_regs
set_multicycle_path -hold -end 1 -from $tms_instr_word -to $tms_decode_regs

# Fitter-only guardband on the 100 MHz fabric clock: placement and routing
# target 0.4 ns of extra setup margin. quartus_sta signs off against the real
# constraints above, so this changes only how hard the fitter works.
if {[string match "quartus_fit*" $::quartus(nameofexecutable)]} {
    set fabric_clk [get_clocks {emu|pll|pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
    set_clock_uncertainty -setup -add -from $fabric_clk -to $fabric_clk 0.4
}
