# Smash T.V. timing constraints.

derive_pll_clocks
derive_clock_uncertainty

#**************************************************************
# Smash T.V. core: SDRAM timing (CL2 @ 96.648 MHz, 180deg clock)
#
# Adopted from the proven Sega System 32 MiSTer core (rtl/mem/sdram.sv there,
# D:\Arcade\AI\s32 -- the same DE10-Nano SDRAM hardware), after a black-screen
# investigation found our controller had no SDC constraints on the SDRAM DQ/
# command bus at all, and generated SDRAM_CLK via an internal altddio_out DDR
# forward instead of the clean PLL phase tap this needs. Both changed to match
# s32 exactly: SDRAM_CLK is now the PLL's outclk2 (already generated at 5174ps
# = 180deg of the 10348ps/96.648MHz period), and the delays below are s32's
# real board-calibrated values (MiSTer SDRAM module, -7 grade), not guessed.
#**************************************************************
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

# Fail the timing flow instead of silently releasing an unconstrained SDRAM bus
# if Quartus changes the generated PLL hierarchy.
if {[get_collection_size $sdram_fwd_pin] != 1} {
    error "Expected exactly one PLL outclk2 pin for the forwarded SDRAM clock"
}
if {[get_collection_size $sdram_mem_clk] != 1} {
    error "Expected exactly one PLL outclk0 clock for the SDRAM controller"
}

create_generated_clock -name SDRAM_CLK -source $sdram_fwd_pin \
    [get_ports SDRAM_CLK]

# board + chip delays (typical MiSTer SDRAM module, -7 grade)
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK -min 3.2 [get_ports SDRAM_DQ[*]]
set_output_delay -clock SDRAM_CLK -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_multicycle_path -setup -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 2
set_multicycle_path -hold -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 1
