# The standard PLL exposes the shifted 48 MHz clock as general[1].
# A reconfigurable game PLL is implemented as a Cyclone-V fPLL instead;
# its duplicated output is merged with counter[0].
# With JTFRAME_180SHIFT the pin is driven by an altddio_out cell from clk_rom,
# general[0], with its data inputs set to invert the clock. general[1] is then
# unused and optimised away, and the pin is general[0] shifted by 180 degrees.
set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
    if { [get_collection_size $sdram_clk_src] == 0 } {
        set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
        create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports SDRAM_CLK]
    } else {
        create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 [get_ports SDRAM_CLK]
    }
} else {
    create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports SDRAM_CLK]
}

# jtframe_sdram_budget: board-level SDRAM interface budget, now part of the real SDC so
# the standard STA, the fitter and the all-condition audit apply the same limits.
# Launch/capture clock is the forwarded SDRAM_CLK (created above). Max in 9.5 ns = tAC(CL2) 6.0 + 2 x 1.0 flight + 0.5 skew + 1.0 margin;
# min in 1.8 ns = tOH; out setup 2.0 / hold -1.3 ns = tIS/tIH incl. flight and skew.
# docs/SDRAM_DQ_CAPTURE.md has the derivation and the all-condition evidence.
set jtframe_sdram_clk [get_clocks -nowarn SDRAM_CLK]
if { [get_collection_size $jtframe_sdram_clk] != 1 } { error {SDRAM_CLK generated clock missing} }
set jtframe_sdram_dq   [get_ports {SDRAM_DQ[*]}]
set jtframe_sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock $jtframe_sdram_clk -max 2.0 $jtframe_sdram_outs
set_output_delay -clock $jtframe_sdram_clk -min -1.3 -add_delay $jtframe_sdram_outs
set_input_delay  -clock $jtframe_sdram_clk -max 9.5 $jtframe_sdram_dq
set_input_delay  -clock $jtframe_sdram_clk -min 1.8 -add_delay $jtframe_sdram_dq
# Edge proof (CL2): the word driven by SDRAM_CLK edge E (launch at E+tAC) is captured by
# the first dout clock (clk_dq = clk_sys + 8.333 ns, PLL outclk_5) edge one period after the
# first edge following E, i.e. launch-to-capture = default relationship + 1 period. The
# following word, launched by E + 1 period, must not reach dout before that same capture
# edge: the hold edge is therefore the default setup edge (setup 2 / hold 0, -end).
set jtframe_sdram_cap [get_registers -nowarn {*|jtframe_sdram64:u_sdram|altddio_in:u_dq_in|*|dataout_h[*]}]
if { [get_collection_size $jtframe_sdram_cap] != 16 } { error {SDRAM altddio_in capture registers must resolve 16 endpoints} }
set_multicycle_path -from $jtframe_sdram_dq -to $jtframe_sdram_cap -setup 2 -end
set_multicycle_path -from $jtframe_sdram_dq -to $jtframe_sdram_cap -hold 0 -end
# altddio_in also instantiates the falling-edge half (ddio_ina DFFLO). Its dataout_l output
# is not connected (zero fanout), so a path ending there cannot influence the design.
set jtframe_sdram_cap_l [get_registers -nowarn {*|jtframe_sdram64:u_sdram|altddio_in:u_dq_in|*|ddio_ina[*]~DFFLO}]
if { [get_collection_size $jtframe_sdram_cap_l] != 16 } { error {SDRAM altddio_in unused falling-edge half must resolve 16 registers} }
set_false_path -from $jtframe_sdram_dq -to $jtframe_sdram_cap_l
