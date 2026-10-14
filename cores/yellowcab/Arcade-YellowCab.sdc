#============================================================================
# Yellow Cab MiSTer - core timing constraints
#
# sys/sys_top.sdc brings in the platform-level constraints (HPS, HDMI, VGA...).
# This file covers the core clock and the asynchronous control paths into it.
#
# The core is all-BRAM and single-clock: one 48 MHz PLL output feeds everything.
# Both 6502s run from clock enables (2 MHz main, 1.5 MHz sound) rather than
# divided clocks, so there are no generated clocks to declare here.
#============================================================================

derive_pll_clocks
derive_clock_uncertainty

set clk_sys {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}

# ---------------------------------------------------------------------------
# Asynchronous / quasi-static inputs.
#
# status[], the DIP switches and the ioctl download stream are driven from the
# HPS side and are either static while the core runs or held for many clocks.
# ---------------------------------------------------------------------------
set_false_path -to   [get_registers {*|sw[*][*]}]
set_false_path -from [get_registers {*|status[*]}]

# Joystick / button inputs are resynchronised in hps_io and are read at 60 Hz.
set_false_path -from [get_registers {emu|joy0[*]}] -to [get_registers {emu|in*[*]}]
set_false_path -from [get_registers {emu|joy1[*]}] -to [get_registers {emu|in*[*]}]

# Reset distribution
set_false_path -from [get_registers {emu|reset}]

# ---------------------------------------------------------------------------
# Multicycle relief on the clock-enabled CPU paths.
#
# The main CPU advances once every 24 clk_sys cycles and the sound CPU once
# every 32, so combinational paths between their registers have far more than
# one clock period to settle. Constraining them at 1 cycle would be pessimistic
# and would make the fitter work against a deadline that does not exist.
# ---------------------------------------------------------------------------
set_multicycle_path -setup -end 4 -from [get_registers {*|u_mcpu|*}] -to [get_registers {*|u_mcpu|*}]
set_multicycle_path -hold  -end 3 -from [get_registers {*|u_mcpu|*}] -to [get_registers {*|u_mcpu|*}]
set_multicycle_path -setup -end 4 -from [get_registers {*|u_acpu|*}] -to [get_registers {*|u_acpu|*}]
set_multicycle_path -hold  -end 3 -from [get_registers {*|u_acpu|*}] -to [get_registers {*|u_acpu|*}]
