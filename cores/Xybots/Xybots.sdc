derive_pll_clocks
derive_clock_uncertainty

# ============================================================================
#  Xybots core timing constraints.
#
#  There is exactly ONE fabric clock in the game half of this design:
#
#     clk_sys = 57.272727 MHz  (emu|pll outclk_0 = PLL 50 MHz x 63 / 5 / 11)
#             = 4 x 14.318181 MHz, the SP-313 sheet-4 master crystal.
#             Period 17.461 ns.
#
#  Everything below it advances on synchronous, integer clock ENABLES generated
#  in rtl/xybots_core.sv from one free-running /32 counter:
#
#     ce_14m  = clk_sys / 4   = 14.318181 MHz  (SYNGEN master, sheet 4)
#     ce_7m   = clk_sys / 8   =  7.159091 MHz  (VIDCLK pixel AND the 68000)
#     ce_ym   = clk_sys / 16  =  3.579545 MHz  (JSA I crystal, = video xtal / 4)
#     ce_6502 = clk_sys / 32  =  1.789772 MHz  (JSA I 6502)
#
#  Each slower enable is a strict subset of every faster one (they are decodes of
#  the same counter), so no fractional/asynchronous enable exists anywhere and
#  there is no CDC inside the game logic.  The only genuine crossing between the
#  two PCBs is the SCOM mailbox, which is modelled with an explicit handshake in
#  rtl/sound/xybots_sound_comm.sv, not with a second clock.
#
#  outclk_1 is the same 57.272727 MHz, phase-shifted, driving the SDRAM_CLK pin.
#
#  ---- the rule the multicycle exceptions below obey --------------------------
#  Without them the analyser holds the big CE-gated cores (the T65, parts of
#  jt51) to the full 17.46 ns period, which is FALSE for registers
#  that provably share one clock enable.  Only INTRA-block reg->reg paths are
#  relaxed, and only inside a hierarchy where every sequential process takes the
#  same Enable.  A CE-gated block's OUTPUTS to full-rate logic stay
#  single-cycle: a full-rate sampler may legitimately latch a held CPU output on
#  any clk_sys edge.  Nothing that runs at the full rate — the SDRAM controller,
#  the graphics arbiter, the motion-object engine, the video pipeline, the bus
#  decode — gets an exception of any kind.
#
#  The main CPU is fx68k, which is NOT one of those blocks — it carries two
#  genuinely full-rate registers (its two microcode ROM output flops) and so
#  gets only the four narrow, author-supplied microcode-address exceptions and
#  nothing else.  See the fx68k section below.
# ============================================================================

# ============================================================================
#  MAIN CPU.  fx68k is the core's only 68000.  The exception block is still
#  guarded by a presence test on its own registers and says in the log which way
#  it went, so a constraint that stops matching because a register got renamed
#  shows up as "not in this build" in the STA log instead of disappearing in
#  silence.
# ============================================================================

# ---- fx68k: the microcode address paths ------------------------------------
# These are Jorge Cwik's OWN constraints, quoted from
# rtl/lib/fx68k/fx68k.txt "Timing analysis" ("Microcode access is one of
# the slowest paths on the core.  But the microcode output is not needed
# immediately"), with only the hierarchy completed for this project's instance
# — which that file says is the part that must be modified.  They are `-start`
# in the original; for a single clock `-start` and `-end` are the same
# relationship, so the form is left as the author wrote it.
#
# WHY THEY ARE TRUE HERE, checked in the source rather than taken on trust:
#   * `Ir` is written only under `enT1`            (fx68k.sv:318-323)
#   * `microAddr` and `nanoAddr` only under `enT1` (fx68k.sv:269-272)
#     — their other leg is the `Clks.pwrUp` cold-reset load (fx68k.sv:265-268),
#       which is not in this `-from` collection.
#   * `enT1 = enPhi1 & (tState == T4) & ~wClk`     (fx68k.sv:178)
#     and one pass of the T-state machine (T1->T2->T3->T4->T1, fx68k.sv:184-197)
#     alternates enPhi1/enPhi2, which xybots_cpu.sv places 4 clk_sys apart
#     inside a clk_sys/8 CPU clock.  So successive `enT1` pulses are **16
#     clk_sys** apart (one 68000 micro-cycle = 2 clock periods), and longer
#     whenever the sequencer inserts T0 waits.
# The launch and the capture are the same enable, 16 clk_sys apart, and the
# exception claims **2**.  That is not a relaxation that has to be believed on
# the author's word; it is a factor of eight inside what the structure proves.
# The combinational cloud it covers is rtl/lib/fx68k/uaddrPla.sv, the opcode PLA.
set fx68k_ir [get_registers -nowarn {*u_main|u_cpu|u_fx68k|Ir[*]}]
if {[get_collection_size $fx68k_ir] > 0} {
	post_message -type info "Xybots SDC: fx68k main CPU present -- applying fx68k.txt microcode multicycle exceptions"
	set_multicycle_path -start -setup -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|microAddr[*]}] 2
	set_multicycle_path -start -hold  -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|microAddr[*]}] 1
	set_multicycle_path -start -setup -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|nanoAddr[*]}] 2
	set_multicycle_path -start -hold  -from [get_registers {*u_main|u_cpu|u_fx68k|Ir[*]}] -to [get_registers {*u_main|u_cpu|u_fx68k|nanoAddr[*]}] 1
} else {
	post_message -type info "Xybots SDC: fx68k main CPU not in this build -- its multicycle exceptions skipped"
}

# ---- fx68k gets NO intra-block "it is all ce_7m anyway" exception -----------
# The T65 block below relaxes a whole vendored core because every retained
# update in it is qualified by one enable.  fx68k does NOT qualify: read
# fx68k.sv:2471-2490,
#
#     module uRom(   input clk, ... );  always_ff @(posedge clk) microOutput <= uRam[ microAddr];
#     module nanoRom(input clk, ... );  always_ff @(posedge clk) nanoOutput <= nRam[ nanoAddr];
#
# — the micro-ROM and nano-ROM output registers take **no clock enable at all**
# and are re-clocked on every one of the 57.272727 MHz edges (the author says
# why in the comment above them: it is what makes the two ROMs infer as block
# RAM).  So the claim "every fx68k register is enable-gated by enPhi1/enPhi2"
# is FALSE, a blanket -from/-to over `*u_fx68k|*` would relax two genuinely
# full-rate M10K read paths, and none is applied.  Every fx68k path other than
# the four above is analysed at the full 17.461 ns period.
# (The `-from` collections above are safe under exactly this reading: they name
# `Ir` only, and `Ir` is enable-gated.  The ROM outputs are neither a source nor
# a destination of any exception in this file.)

# ---- JSA I 6502 only --------------------------------------------------------
# The datapath sequential processes in T65.vhd use the same Enable input, which
# rtl/sound/xybots_jsa.sv drives from ce_6502 = clk_sys/32.  Eight cycles is
# deliberately conservative against the real 32-clock interval, and it keeps the
# exception away from anything that might be re-timed into it.  The collection
# is the T65 core inside the wrapper only — the wrapper's own flat-port glue,
# the mailbox, the mixer and the LPF are ordinary full-rate paths.
# Reset synchronizers are full-rate and must retain normal timing.
set xybots_t65_ce [get_registers {*u_jsa|u_cpu|u_t65|*}]
set xybots_t65_reset [get_registers -nowarn {*u_jsa|u_cpu|u_t65|Res_n_i *u_jsa|u_cpu|u_t65|Res_n_d}]
set xybots_t65_ce [remove_from_collection $xybots_t65_ce $xybots_t65_reset]
if {[get_collection_size $xybots_t65_ce] == 0} {error "Xybots T65 CE endpoint collection empty"}
set_multicycle_path -setup -end 8 -from $xybots_t65_ce -to $xybots_t65_ce
set_multicycle_path -hold  -end 7 -from $xybots_t65_ce -to $xybots_t65_ce

# ---- jt51 LFO / channel registers into the phase generator ------------------
# jt51 drives the LFO PM value, the channel frequency/modulation registers and
# the operator register file from cen_p1, which xybots_jsa wires to ce_6502; the
# phase generator's keycode_II destination is clocked by the same enable.  At
# 57.27 MHz successive cen_p1 pulses are 32 fabric clocks apart, so these data
# cannot be launched and captured on adjacent clk_sys edges.  The exception is
# kept on the exact source blocks and the exact destination rather than
# relaxing all of jt51: its timer flags and wrapper state do NOT uniformly share
# this enable.  Two clocks is deliberately conservative, with the standard N-1
# hold adjustment.
set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_lfo|pm[*]}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kc[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|kf[*]* *u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_ch|pms[*]*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

set_multicycle_path -setup -end 2 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]
set_multicycle_path -hold -end 1 \
  -from [get_registers {*u_jsa|u_ym|u_jt51|u_mmr|u_reg|u_csr_op|u_reg1op|*}] \
  -to   [get_registers {*u_jsa|u_ym|u_jt51|u_pg|keycode_II[*]}]

# ============================================================================
#  SDRAM external I/O timing (MT48LC16M16 class, CL2, 57.272727 MHz controller).
#
#  SDRAM_CLK is PLL outclk_1 (the SECOND output counter, general[1]) wired
#  straight to the pin in Arcade-Xybots.sv -- a clean phase-controlled clock, so
#  these delays can actually close.  Datasheet values, same chip class as the
#  sibling cores.  If Quartus reports the -source PLL node cannot be found, open
#  Timing Analyzer -> Report Clocks and substitute the actual outclk_1
#  ...general[1]...divclk path; if it does not apply, the SDRAM I/O simply falls
#  back to unconstrained rather than failing the build.
#
#  Retain the user-approved +13095ps phase.  Native reports must isolate
#  DQ->dq_fall capture and dq_fall->rdata publication at every supported
#  condition; summary rows alone do not qualify either path.  The external
#  delay contract below uses the existing part-class limits; board flight
#  and skew are not characterized by a historical hardware phase sweep.
# ============================================================================
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# Read capture: data access time tAC = 6.0 ns (max), output hold tOH = 2.5 ns (min).
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data launch: input setup tIS = 1.5 ns (max), hold tIH = 0.8 ns (min).
set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# Original CL2/consecutive-READ timing, with unchanged direct clock forwarding.
# READ pin at sys0 -> external acceptance phi -> data launch phi+T ->
# capture sys3T.  Setup relationship = 2T-phi = 21.8256ns, so end-setup2.
# Next word launches at phi+2T; hold relationship is capture-minus-launch
# T-phi = 4.3653ns.  Setup2's default hold already describes that edge.
# DO NOT use end-hold1: across these shifted clocks it moves the hold latch
# back a whole period and checks the previous capture (relationship -phi).
# Restrict the contract to all16DQ inputs and every physical rdata copy.
set xybots_dq [get_ports {SDRAM_DQ[*]}]
set xybots_rdata [get_registers {*u_sdram|rdata[*]*}]
if {[get_collection_size $xybots_dq] != 16} {error "Xybots requires16DQ ports"}
if {[get_collection_size $xybots_rdata] < 16} {error "Xybots requires all rdata endpoints"}
set_multicycle_path -setup -end 2 -from $xybots_dq -to $xybots_rdata
set_multicycle_path -hold -end 0 -from $xybots_dq -to $xybots_rdata
