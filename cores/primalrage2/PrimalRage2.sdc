derive_pll_clocks
derive_clock_uncertainty


# --------------------------------------------------------------------------
# PR2 SDRAM source-synchronous interface
#
# The controller forwards inverted outclk_2 through altddio_out to SDRAM_CLK.
# Constrain the physical forwarded clock including the output-cell delay,
# and the actual DQ capture registers. A raw PLL tap routed directly to the
# board pin incurs excessive clock skew.
# --------------------------------------------------------------------------
set pr2_sdram_clk_src [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set pr2_sdram_dq_capture [get_registers -nowarn \
    {*|sdram:sdram|dq_reg[*]}]
if {[get_collection_size $pr2_sdram_clk_src] == 1 && \
    [get_collection_size $pr2_sdram_dq_capture] > 0} {
    create_generated_clock -name SDRAM_CLK -source $pr2_sdram_clk_src -invert \
        [get_ports SDRAM_CLK]

    # AS4C32M16SB-7 / W9825G6KH-class MiSTer 128 MB SDRAM contract.
    # tAC(max)=6.0 ns and tOH(min)=2.5 ns; command/data setup/hold are
    # tIS=1.5 ns and tIH=0.8 ns. These values are board-interface limits,
    # not timing waivers.
    set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
    set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
    # DQ is captured on the rising clk3x edge, one cycle later than the
    # nearest rising edge after the forwarded SDRAM clock. This is the
    # previous beat's 1.5-period return window; the RTL pipelines its valid
    # token by one cycle. Keep hold at zero multicycles: hold=1 would hide
    # the next beat overwriting this continuously streaming input.
    set_multicycle_path 2 -setup -end -from [get_ports {SDRAM_DQ[*]}] -to $pr2_sdram_dq_capture
    set_multicycle_path 0 -hold -end -from [get_ports {SDRAM_DQ[*]}] -to $pr2_sdram_dq_capture
    set pr2_sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
        SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE \
        SDRAM_CKE}]
    set_output_delay -clock SDRAM_CLK -max 1.5 $pr2_sdram_out
    set_output_delay -clock SDRAM_CLK -min -0.8 $pr2_sdram_out

    # The internal dq_reg-to-burst transfer remains an ordinary full-cycle
    # path. No exception applies to that register-to-register transfer.
} elseif {[string match "quartus_map" $::quartus(nameofexecutable)]} {
    post_message -type warning \
        "PR2 SDC: deferring SDRAM pin/capture constraints until fitted netlist"
} else {
    error "PR2 SDC: expected one controller PLL outclk_2 and dq_reg capture bank"
}

create_generated_clock -name {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -source {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|vco0ph[0]} -divide_by 5 -multiply_by 1 -duty_cycle 50.00 { emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk }

set_false_path -from {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -to {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -to {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from {FPGA_CLK1_50} -to {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from {FPGA_CLK2_50} -to {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}

set_false_path -from {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set_false_path -from {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set_false_path -from {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set_false_path -from {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk}
set_false_path -from {emu|pll2|pll2_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -to {FPGA_CLK1_50}
