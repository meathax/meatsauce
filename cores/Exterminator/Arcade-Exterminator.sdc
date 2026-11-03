# Exterminator timing constraints (lane 4 scaffold).
#
# Clocks (rtl/pll, 50 MHz ref): outclk0 80 MHz clk_ram, outclk1 20 MHz clk_sys, outclk2 80 MHz +180 deg SDRAM_CLK.
# clk_sys is an exact 1:4 divide of clk_ram from the same VCO (phase aligned, treated as related clocks).
# Core multicycle/false-path exceptions belong to the lane that proves them (mister-timing-closure.md);
# none are added here.

derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM interface -- structure copied from the hardware-proven NARC SDC (same DE10-Nano SDRAM
# module, CL2).  SDRAM_CLK is PLL outclk2 driving the pin directly (clean generated clock the SDC
# can reference).  I/O delays: tAC 6.4 / tOH 2.5 (incl. board), tIS 1.5 / tIH 0.8.  The outclk2 phase
# (rtl/pll/pll_pll_inst.v phase_shift2, 8906 ps) and the read beat below were derived from post-fit STA.
# Do not weaken any of them to close timing.
# ---------------------------------------------------------------------------
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

# Fail the timing flow instead of silently releasing an unconstrained SDRAM bus if Quartus
# changes the generated PLL hierarchy.
if {[get_collection_size $sdram_fwd_pin] != 1} {
    error "Expected exactly one PLL outclk2 pin for the forwarded SDRAM clock"
}
if {[get_collection_size $sdram_mem_clk] != 1} {
    error "Expected exactly one PLL outclk0 clock for the SDRAM controller"
}

create_generated_clock -name SDRAM_CLK -source $sdram_fwd_pin [get_ports SDRAM_CLK]

set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports SDRAM_DQ[*]]
set_output_delay -clock SDRAM_CLK -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
# CL2 starts driving after the first chip edge following READ, valid by the
# second. For READ issued at controller E0, dq_in samples the selected word at
# E3; cl_pipe[3] consumes it at E4. The setup-end 2 input relationship qualifies
# this sample against the forwarded pad clock. No hold relaxation: consecutive
# READs replace DQ every clock, and BL1 releases DQ after its one data window.
# cl_pipe[4] would instead consume the E4 sample, outside that window; an input
# exception cannot extend the chip's physical drive duration.
set_multicycle_path -setup -end -from [get_clocks SDRAM_CLK] -to $sdram_mem_clk 2
