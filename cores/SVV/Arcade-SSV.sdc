# SSV MiSTer core timing constraints.
# Board clocks (FPGA_CLK*_50, HPS user clocks) are created in sys/sys_top.sdc.
# Do not invent a CLK_50M / RESET / HPS_BUS top-level here — the compiled
# entity is sys_top, and those emu-wrapper names do not exist as ports.

derive_pll_clocks

#**************************************************************
# SDRAM interface (single 64Mx16 module on GPIO0, CL2, clk_ram
# 96.648 MHz, SDRAM_CLK forwarded from PLL outclk2 at 180 deg)
#
# Until this block existed the SDRAM bus was COMPLETELY
# unconstrained: SDRAM_CLK had no clock, so no DQ capture path
# was ever analysed and STA reported "met" while saying nothing
# about the read path.  Precedent for constraining it this way
# is the sibling Sega System 32 core,
#   D:\Arcade\AI\s32\Arcade-SegaSystem32.sdc lines 23-52,
# which has an identical topology (outclk0 = clk_ram 96.63 MHz,
# outclk2 = SDRAM_CLK at 180 deg, CL2, same DE10-Nano module),
# and D:\Arcade\AI\aCORES\Sega Y Board\Arcade-SegaYBoard.sdc
# lines 4-17 which carries the same four delay numbers.
#
# Honest note on "common practice": most MiSTer cores do NOT
# constrain SDRAM at all -- not even false-path it.  sys/sys_top.sdc
# here, Template.sdc, Arcade-IremM92.sdc, Arcade-MrDo.sdc,
# Arcade-YellowCab.sdc and Ikki.sdc contain zero SDRAM references.
# The jtframe framework
#   D:\Arcade\AI\aCORES\Sega Y Board\third_party\jtcores\modules\
#   jtframe\target\mister\syn\sdram_clk96.sdc
# creates the SDRAM_CLK generated clock and the same read-capture
# multicycle exception, but supplies no set_input_delay /
# set_output_delay at all.  So the generated clock + multicycle
# pair is established practice; the I/O delay values below are
# only precedented by the two sibling cores above.
#**************************************************************

# quartus_map runs before the PLL output counters exist in the
# netlist, and create_generated_clock against an empty -source
# is a hard error there.  s32 hit exactly this (its audit note
# R20 PF-5: the error fired at quartus_map and silently disabled
# timing-driven synthesis).  Warn during synthesis, fail during
# fit/STA where the objects must exist.
proc ssv_require {present what} {
    if {$present} { return 1 }
    if {[string match "quartus_map" $::quartus(nameofexecutable)]} {
        post_message -type warning \
            "SSV SDC: $what not elaborated yet; deferring to fit/STA"
        return 0
    }
    error "SSV SDC: expected $what but it is missing at $::quartus(nameofexecutable)"
}

# outclk2 -> SDRAM_CLK, outclk0 -> clk_ram.  Index confirmed against
# output_files/Arcade-SSV.sta.rpt "Clocks" table: general[2] is the
# 10.348 ns / 96.63 MHz output with Phase 180.0, general[0] is the
# 10.348 ns 0-degree output.  The 180 deg shift lives inside the PLL
# (rtl/pll/pll.qsys gui_phase_shift2 = 5174 ps = half of 10.348 ns),
# so no -phase argument is needed here -- derive_pll_clocks already
# carries it on the source.
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

if {[ssv_require [expr {[get_collection_size $sdram_fwd_pin] == 1 && \
                        [get_collection_size $sdram_mem_clk] == 1}] \
        "exactly one PLL outclk2 pin and outclk0 clock for the SDRAM bus"]} {

create_generated_clock -name SDRAM_CLK -source $sdram_fwd_pin \
    [get_ports SDRAM_CLK]

# ---- Read path: DQ arriving from the chip, referenced to SDRAM_CLK ----
#
# *** THESE FOUR DELAY NUMBERS ARE ENGINEERING ESTIMATES, NOT      ***
# *** MEASURED AND NOT TAKEN FROM THE DATASHEET OF THE PARTICULAR  ***
# *** MODULE FITTED TO THIS DE10-NANO.  They are the generic       ***
# *** -7 grade SDR SDRAM AC values plus an assumed ~1 ns board     ***
# *** round trip, and they match the two sibling cores cited above.***
# *** To replace them with real numbers you need (a) the module's  ***
# *** part number and speed grade, for tAC / tOH / tDS / tDH, and  ***
# *** (b) the GPIO0 trace flight time, either from the DE10-Nano   ***
# *** schematic or from a board-level measurement.  Treat the      ***
# *** resulting slack as indicative until then.                    ***
#
# max 6.4 ns  = tAC(CL2) 5.4 ns for a -7 part (data valid after the
#               clock edge at the chip) + ~1.0 ns assumed round-trip
#               board delay (clock out + data back on GPIO0).
# min 3.2 ns  = tOH 2.5 ns (data hold after the clock edge) + ~0.7 ns
#               assumed minimum board delay.
# (Port patterns are brace-quoted: bare SDRAM_DQ[*] is a Tcl command
# substitution of "*", so the braces are required, not stylistic.)
set_input_delay  -clock SDRAM_CLK -max 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 3.2 [get_ports {SDRAM_DQ[*]}]

# ---- Write / command / address group, launched by clk_ram ----
#
# max  1.5 ns = tDS / tAS, the input setup the chip requires before
#               its clock edge, for a -7 part.
# min -0.8 ns = -tDH / -tAH, the input hold the chip requires after
#               its clock edge (output min delay carries the hold
#               requirement negated, per the standard convention).
# SDRAM_DQ appears in both groups because it is bidirectional.
set_output_delay -clock SDRAM_CLK -max 1.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
                SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]

# Read capture edge.  SDRAM_CLK is 180 deg late, so its rising edge
# is at 5.174 ns while clk_ram (rtl/mem/sdram.sv:621, dq_in <= SDRAM_DQ)
# captures at 0 / 10.348 ns.  By default STA would try to close the
# 6.4 ns input delay onto the clk_ram edge only 5.174 ns after the
# launch -- an edge the data physically cannot make -- so the real
# capture edge is one clk_ram period later.  -setup -end 2 selects it;
# -hold -end 1 keeps the hold check on the adjacent edge.  Same
# exception as s32 lines 47-50 and jtframe sdram_clk96.sdc lines 6-8.
# Nothing in the design is clocked BY SDRAM_CLK, so this exception
# touches only the DQ input capture paths.
set_multicycle_path -setup -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 2
set_multicycle_path -hold -end -from [get_clocks SDRAM_CLK] \
    -to $sdram_mem_clk 1

}

# After the SDRAM clock exists, so its uncertainty is derived too.
derive_clock_uncertainty

# The V60 is clock-enabled at approximately 16.1 MHz from clk_sys.  The
# accumulator ratio guarantees at least three clk_sys periods between enable
# pulses, and every V60 state register is updated by the same `ce` branch.
# Constrain only register-to-register paths wholly inside that instance.
set v60_registers [get_registers {*|s32_v60:cpu|*}]
set v60_registers [add_to_collection $v60_registers \
    [get_registers {*|s32_v60_bus:bus_adapter|*}]]
set_multicycle_path -setup 3 \
    -from $v60_registers -to $v60_registers
set_multicycle_path -hold 2 \
    -from $v60_registers -to $v60_registers

# ES5506 voice CE domain (~16 MHz, same ratio as V60). Only CE-updated
# registers get the multicycle; SDRAM handshake regs (sdr_*, got_ack,
# wait_cnt, s1/s2) stay single-cycle on clk_sys.
set voice_ce_registers [get_registers {*|ssv_es5506_voice:sound_voices|state*}]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|voice_i*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|proc_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|mix_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|audio_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|cr*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|fc*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|lvol*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|rvol*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|accum*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|o*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|eng_*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|filtcount*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|vstart*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|vend*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|k1*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|k2*}]]
set voice_ce_registers [add_to_collection $voice_ce_registers \
    [get_registers {*|ssv_es5506_voice:sound_voices|ecount*}]]
set_multicycle_path -setup 3 \
    -from $voice_ce_registers -to $voice_ce_registers
set_multicycle_path -hold 2 \
    -from $voice_ce_registers -to $voice_ce_registers
