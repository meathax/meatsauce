# sys/sys_top.sdc owns the physical 50 MHz input clocks. This project-level
# file only derives clocks; emu's CLK_50M is an internal port alias and is not
# a top-level Quartus port.
derive_pll_clocks
derive_clock_uncertainty

# Core-specific clocks will be added only when the implementation exposes
# additional generated-clock domains. No false paths are used in bring-up.
