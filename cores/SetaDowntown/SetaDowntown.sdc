derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# fx68k multicycle, with its audit.
#
# fx68k advances only on enPhi1 / enPhi2, which maincpu.sv generates cpu_half
# clk apart: 6 nominal / 3 minimum during stall-debt recovery in the
# production 8 MHz profile. Smaller legacy half-periods do not accelerate.
# A held phi2 is later. fx68k is written for enables on consecutive clocks, so its internal
# paths are single-cycle designs, and its README gives close to 40 MHz; at
# 96 MHz it needs this constraint.
#
# AUDIT (rtl/cpu/fx68k/fx68k.sv, fx68kAlu.sv): every always_ff that carries
# data assigns under enPhi1, enPhi2 or enT1..enT4 (themselves enPhi1/enPhi2
# qualified by tState), or under pwrUp / extReset, which are held for many
# clocks. The exceptions are the microcode and nanocode ROM output registers
# (uRom, nanoRom: `microOutput <= uRam[microAddr]` every clock). Their address
# latches on enT1 and microLatch / nanoLatch take the output on enT3, two
# phases (at least 6 clk) later, so the ROM register holds the settled value
# for at least 3 clk before it is used: 3 cycles is safe through it too.
#
# Scoped to fx68k-internal paths. The bus signals into and out of maincpu.sv
# (AS, strobes, eab, DTACK, iEdb, IPL) cross at full clk_sys.
# ---------------------------------------------------------------------------
set fx68k [get_registers {*maincpu:u_cpu|fx68k:u_cpu|*}]
set_multicycle_path -setup -from $fx68k -to $fx68k 3
set_multicycle_path -hold  -from $fx68k -to $fx68k 2

# ---------------------------------------------------------------------------
# The game selector is STATIC. It is the .mra mod byte, latched from ioctl
# index 1 during the ROM download and never changed while the game runs --
# and the download completes before the core comes out of reset.
#
# It has to be said, because rtl/seta_board_cfg.sv fans it out into every
# per-game constant and maincpu.sv's whole address decode.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*mod_byte*}]

# ---------------------------------------------------------------------------
# SDRAM pin contract: MT48LC16M16A2 -75/-7E, Micron 256Mb_sdr.pdf
# Rev W 05/15 tables14/15 and CL2 READ waveform. Qualifies this envelope,
# not a measured identification of the user's SDRAM module/PCB.
# https://www.mouser.com/datasheet/2/671/256Mb_sdr-1282350.pdf
# tAC max6ns; tOH no-load min1.8ns (stricter than loaded3ns).
# Board clock and DQ flight each0.1..0.5ns, counted twice on input.
# Writes/commands allow worst relative clock/data board skew0.5ns.
set sdram_tAC 6.0
set sdram_tOH 1.8
set sdram_tDS 1.5
set sdram_tDH 0.8
set sdram_board 0.5
set sdram_board_min 0.1
set sdram_clock_pin [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $sdram_clock_pin] != 1} {error "SDRAM clock source cardinality"}
create_generated_clock -name sdram_clk_pin -source $sdram_clock_pin -invert [get_ports {SDRAM_CLK}]
set sdram_dq_ports [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $sdram_dq_ports] != 16} {error "SDRAM DQ port cardinality"}
set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + 2*$sdram_board}] $sdram_dq_ports
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + 2*$sdram_board_min}] $sdram_dq_ports
# Capture the previous launched beat a full period plus3386ps after the
# SDRAM rising launch. The next word launches10416ps later, BEFORE this
# capture: hold-end0 checks it; hold-end1 would hide a whole period.
# Native03 per-pin four-corner bounds precede this exact16pin exception.
set dt_dq_capture [get_registers {*sdram:u_sdram|dq_pin[*]}]
if {[get_collection_size $dt_dq_capture] != 16} {error "SDRAM capture cardinality"}
set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk_pin}] -to $dt_dq_capture
set_multicycle_path -hold -end 0 -from [get_clocks {sdram_clk_pin}] -to $dt_dq_capture
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}] $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH - $sdram_board}] $sdram_outs

# ---------------------------------------------------------------------------
# Thundercade's YM2203 (jt03:u_ym0 in seta_core): jt12
# phase-generator multicycle 2, as Arcade-Fuuki_MiSTer's Fuuki.sdc applies it
# to the same unmodified jt12.
# Audit (Fuuki's): jt12_pg.v has one clocked block, under `if (clk_en)`,
# holding keycode_II / detune_mod_II / phinc_II; jt12_sh_rst.v (u_phsh, u_pad)
# has one clocked block under `if (clk_en)`. clk_en is jt12_div's
# `cen & cen_int`, and cen is seta_core's dt_ym_cen at 1/24 of clk_sys, so
# both ends tick >= 24 clk apart. jt12_reg's cur_ch / cur_op and jt12_lfo's
# lfo_mod are under clk_en too; lfo_mod's only full-rate branch is the lfo_en
# clear, itself changed only by cen-cadenced MMR writes. Collections name
# registers, not subtrees. Empty in the Seta revision, which has no YM2203.
# ---------------------------------------------------------------------------
set jtsrc [get_registers {*|jt03:u_ym0|*jt12_reg:u_reg|cur_ch[*] *|jt03:u_ym0|*jt12_reg:u_reg|cur_op[*] *|jt03:u_ym0|*jt12_lfo:*|lfo_mod[*] *|jt03:u_ym0|*jt12_pg:u_pg|phinc_II[*] *|jt03:u_ym0|*jt12_pg:u_pg|keycode_II[*] *|jt03:u_ym0|*jt12_pg:u_pg|detune_mod_II[*] *|jt03:u_ym0|*jt12_mmr:u_mmr|effect}]
set jtdst [get_registers {*|jt03:u_ym0|*jt12_pg:u_pg|phinc_II[*] *|jt03:u_ym0|*jt12_pg:u_pg|keycode_II[*] *|jt03:u_ym0|*jt12_pg:u_pg|detune_mod_II[*] *|jt03:u_ym0|*jt12_pg:u_pg|jt12_sh_rst:u_pad|* *|jt03:u_ym0|*jt12_pg:u_pg|jt12_sh_rst:u_phsh|*}]
if {[get_collection_size $jtsrc] > 0 && [get_collection_size $jtdst] > 0} {
    set_multicycle_path -setup -end 2 -from $jtsrc -to $jtdst
    set_multicycle_path -hold  -end 1 -from $jtsrc -to $jtdst
} else {
    post_message -type info \
        "Seta.sdc: no jt03 -- the jt12 phase-generator multicycle is not applied (expected in the Seta revision)"
}

# Extra routing margin for related96MHz->48MHz fabric hold transfers.
# Preserve derive_clock_uncertainty and every launch/capture relationship;
# add200ps rather than relaxing the reported hold failure. Quartus17 supports
# -add/-enable_same_physical_edge (official sdc1.5 command reference).
set dt_hold_from [get_clocks {*pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set dt_hold_to [get_clocks {*pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $dt_hold_from] != 1 || [get_collection_size $dt_hold_to] != 1} {error "Downtown hold clock cardinality"}
# This unmeasured200ps is an implementation guard only. Final STA retains
# all derived physical uncertainty, without treating the guard as jitter.
if {[info exists ::quartus(nameofexecutable)] && $::quartus(nameofexecutable) eq "quartus_fit"} {
 set_clock_uncertainty -hold -enable_same_physical_edge -add 0.200 -from $dt_hold_from -to $dt_hold_to
 set_clock_uncertainty -hold -enable_same_physical_edge -add 0.300 -from $dt_hold_to -to $dt_hold_from
}

# Capture-to-fabric routing budget: normal related-clock setup is 7.030ns
# before skew/uncertainty. A 5ns maximum tightens that relationship; hold
# remains normally timed. Include physical duplicates of each logical bit.
set dt_capture_route [get_registers {*sdram:u_sdram|dq_pin*}]
set dt_capture_stage [get_registers {*sdram:u_sdram|dq_in*}]
if {[get_collection_size $dt_capture_route] < 16 || [get_collection_size $dt_capture_stage] < 16} {error "SDRAM stage routing endpoints missing"}
if {[info exists ::quartus(nameofexecutable)] && $::quartus(nameofexecutable) eq "quartus_fit"} {
 set_max_delay 5.000 -from $dt_capture_route -to $dt_capture_stage
}
