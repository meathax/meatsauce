derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# Ported from the donor's projects/ncv1_pocket.sdc (timing closed there at 96 MHz).
# The multicycle relaxations are safe because the logic only advances on its clock
# enable: cen_h8 (16.384 MHz of 96 MHz) is never closer than 5 clocks apart,
# fx68k's phi1/phi2 enables (24.576 M pulses/s) never closer than 3.

set CLK_SYS   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]

# SDRAM: pin clock is PLL output 1 (phase-shifted 96 MHz) driven through altddio_out.
# Delays are the donor's Pocket values; the MiSTer board routing differs, so these
# are to be re-verified by the build/timing step (mister-rbf-build), not trusted blindly.
create_generated_clock -name sdram_clk -source \
    [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {SDRAM_CLK}]
set_input_delay -max -clock sdram_clk 7.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -min -clock sdram_clk 2.5 [get_ports {SDRAM_DQ[*]}]
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_CKE SDRAM_DQML SDRAM_DQMH SDRAM_DQ[*] SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS}]
set_output_delay -max -clock sdram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock sdram_clk -0.8 $SDRAM_OUT
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# H8/300H: advances only on cen_h8
set H8CORE   [get_registers {*|h8300h_core:*|*}]
set H8DIV    [get_registers {*|h8300h:*|div_q[*] *|h8300h:*|div_rem[*]}]
set H8RST    [get_registers {*|ncv1_core:*|h8_reset}]
set H8PERIPH [get_registers {*|h83002:*|*}]
set_multicycle_path -setup 5 -from $H8CORE   -to $H8CORE
set_multicycle_path -hold  4 -from $H8CORE   -to $H8CORE
set_multicycle_path -setup 5 -from $H8RST    -to $H8CORE
set_multicycle_path -hold  4 -from $H8RST    -to $H8CORE
set_multicycle_path -setup 5 -from $H8PERIPH -to $H8CORE
set_multicycle_path -hold  4 -from $H8PERIPH -to $H8CORE
set_multicycle_path -setup 5 -from $H8DIV    -to $H8CORE
set_multicycle_path -hold  4 -from $H8DIV    -to $H8CORE

# fx68k: advances only on its phi enables
set FX [get_registers {*|fx68k:*|*}]
set_multicycle_path -setup 3 -from $FX -to $FX
set_multicycle_path -hold  2 -from $FX -to $FX
