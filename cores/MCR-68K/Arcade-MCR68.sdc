derive_pll_clocks
derive_clock_uncertainty

# The game and MiSTer video clocks are synchronous outputs of one core PLL.
# The standard framework SDC groups every other MiSTer clock; add the active
# core-owned outputs here while retaining their generated relationship.
set core_video_clk [get_clocks {*emu|pll|pll_inst|*|divclk}]
set non_core_video_clks [remove_from_collection [all_clocks] $core_video_clk]
set_clock_groups -asynchronous \
    -group $core_video_clk \
    -group $non_core_video_clks

set core_logic_clk [get_clocks {*emu|pll|pll_inst|*general*0*gpll*PLL_OUTPUT_COUNTER*divclk}]
set sdram_shift_clk [get_clocks {*emu|pll|pll_inst|*general*1*gpll*PLL_OUTPUT_COUNTER*divclk}]

# PLL pin/register objects are unavailable during analysis and synthesis, but
# must exist in the fitted netlist used by TimeQuest. Defer only that early
# check; never silently omit the SDRAM constraints during fit or STA.
proc mcr68_require {present what} {
    if {$present} { return 1 }
    if {[string match "quartus_map" $::quartus(nameofexecutable)]} {
        post_message -type warning \
            "MCR68 SDC: $what not elaborated yet; deferring to fit/STA"
        return 0
    }
    error "MCR68 SDC: expected $what but it is missing at $::quartus(nameofexecutable)"
}

# The core PLL supplies both the 50 MHz memory clock and its fitted,
# near-180-degree SDRAM pin clock, following the established MiSTer topology.
set sdram_mem_clk $core_logic_clk
set sdram_ext_clk $sdram_shift_clk

if {[mcr68_require [expr {[get_collection_size $sdram_mem_clk] == 1 && \
                          [get_collection_size $sdram_ext_clk] == 1}] \
        "the core and phase-shifted SDRAM clocks"]} {

# Conservative MiSTer SDRAM module I/O delays. The forwarded clock is the
# PLL's 50 MHz clock shifted by half a cycle; exact fitted clock objects and
# margins must be audited before accepting an RBF.
set_input_delay -clock $sdram_ext_clk -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay -clock $sdram_ext_clk -min 3.2 [get_ports SDRAM_DQ[*]]
set_output_delay -clock $sdram_ext_clk -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock $sdram_ext_clk -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]

# dq_in <= SDRAM_DQ is unconditional, every clk_ram cycle (rtl/mem/yb_sdram.sv)
# -- it is not gated by a read strobe. Setup/hold at this register must
# therefore hold every single cycle, which is exactly the plain one-cycle
# input-delay relationship TimeQuest derives by default from SDRAM_CLK and
# the set_input_delay values above. A prior version of this file added a
# 2-cycle setup / 1-cycle hold multicycle exception here, justified by the
# captured word not being *consumed* until the cl_pipe drain -- but that is
# irrelevant to the capture register's own timing, and the exception halved
# the effective setup budget TimeQuest was checking without changing
# anything in real silicon. The reference System 32 core (this project's
# stated SDRAM/build-flow pattern source, see README) has the identical
# unconditional dq_in <= SDRAM_DQ register and constrains it with only
# set_input_delay, no multicycle. Do not reintroduce one without a report
# proving the true external round-trip delay needs it.

}
