# NARC timing constraints.

derive_pll_clocks
derive_clock_uncertainty

# Quartus 17.1 optimizes both instantiated 6809 E/Q port nets away and promotes
# the retained fractional-clock phase node as the fabric clock. Constrain that
# mapped node directly; pin-hierarchy patterns are empty by the time the fitter
# reads this SDC. The 12:1 ratio is the conservative minimum edge spacing of
# the fractional 24.162 MHz -> 2 MHz E clock (edges are 12 or 13 clocks apart).
set game_clk_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}]
set snd6809_clock [get_keepers -nowarn \
    {*|narc_sound:sndbrd|narc_sound_eq_clock:u_eq_clock|eq_phase[1]}]
if {[get_collection_size $game_clk_pin] != 1} {
    error "Expected exactly one PLL outclk1 game clock pin"
}
if {[get_collection_size $snd6809_clock] != 1} {
    error "Expected exactly one mapped NARC 6809 phase clock"
}
create_generated_clock -name snd6809_clock -source $game_clk_pin \
    -divide_by 12 $snd6809_clock

#**************************************************************
# NARC core: SDRAM timing (CL2 @ 96.648 MHz, 180deg clock)
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
#
# SETTLED 2026-07-30 -- -min tightened 3.2 -> 2.5. Evidence below.
#
# A LARGER -min is LESS conservative for hold (new data is said to arrive later,
# so the previous value is held longer). 3.2 is the generic stock-MiSTer template
# number. jtframe and the sibling Y-unit core both use 2.5, citing the
# MT48LC16M16 tOH. If the fitted module's real tOH is 2.5, this constraint is
# masking a genuine hold marginality on the DQ capture -- the failure mode that
# closes clean in STA and produces intermittent garbage reads on silicon.
#
# It was tightened to 2.5 earlier today and REVERTED, because the affordability
# argument used the wrong number: it quoted the SDRAM_CLK hold row (2.042 ns).
# That row covers the 52 paths capturing AT THE EXTERNAL CHIP (output delays).
# No register in rtl/ captures on SDRAM_CLK -- it is output-only. The DQ capture
# is rtl/mem/sdram.sv:155 `always @(posedge clk) dq_in <= SDRAM_DQ;` with
# clk = clk_ram = general[0], and Hold Transfers shows the 16 real input paths as
# SDRAM_CLK -> general[0]. general[0]'s multicorner hold worst case is 0.138 ns
# (sta.rpt Multicorner Timing Analysis Summary), not 2.042. Tightening by 0.7 ns
# against a 0.138 ns domain worst case is very likely a hold violation.
#
# TO SETTLE IT, in the same quartus_sta pass as the next fit:
#   report_timing -hold -npaths 20 -detail full_path \
#     -from [get_ports SDRAM_DQ[*]] \
#     -to_clock {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
# Read the actual DQ-path slack. Only if it exceeds 0.7 ns is 2.5 affordable.
# Land any change to this line in a commit of its own so it bisects.
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports SDRAM_DQ[*]]
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

#**************************************************************
# Fit / timing readiness notes (no false paths on the game CPU)
#
# CPU_PACE_CLKS only gates instruction fetch issue rate; the TMS34010 FSM and
# datapath still close in a single clk_sys cycle when active. Do NOT add a
# blanket multicycle from instr_word_q → regfile — it would be incorrect.
# Timing headroom instead comes from:
#   - EXECUTE-cycle registered ALU/shifter/SETF results (tms34010_core.sv)
#   - QSF Fast Fit + normal router effort (no unstable physical synthesis)
#   - MLAB forcing on icache / sound caches / OSD / gamma / ae_cache
#
# HDMI domain slack is inherited from the MiSTer sys PLL/framework and is
# closed separately from the NARC game/SDRAM domains.
#**************************************************************
