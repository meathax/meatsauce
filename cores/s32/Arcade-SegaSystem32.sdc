derive_pll_clocks
derive_clock_uncertainty

# sys/sys_top.sdc (vendored, not modified here) already relaxes several
# sys/osd.v internal counters this way -- e.g.
# `set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2` -- and false-paths the
# rarely-changing sources that feed them (`rot`, `dsp_width`). `pixsz`/
# `pixcnt` (the OSD's pixel-scaling reload counter) are the same class of
# signal but are not in that list: pixsz is a configuration value reloaded
# only on a mode/rotation change and held stable for many clk_video cycles
# afterward, while pixcnt's comparison against it happens continuously: by
# the time pixcnt actually reaches pixsz's value, pixsz has been stable for
# a long time, so this path never needs single-cycle timing to be correct.
# 2026-08-05: this RBF's resource/placement profile (see memory
# s32-single-profile-roadmap) pushed pixsz->pixcnt to -0.299 ns setup slack,
# the only remaining timing failure once the game-logic clock domain
# (rtl/s32_core.sv's mixer pixel/display-X pipeline fix) was closed. Adding
# the missing sibling exception here, not in the vendored sys/osd.v/
# sys_top.sdc, since s32.sdc is this project's own file.
set_multicycle_path -to {*_osd|pixcnt*} -setup 2
set_multicycle_path -to {*_osd|pixcnt*} -hold 1

# 2026-08-05 (same sweep): fixing pixcnt above exposed `multiscan` as the new
# worst path (-0.379 ns), fed both by osd.v's own h_cnt-derived per-frame
# selector logic and, via sys_top.v's shared clk_video composition, by
# HDMI_shadowmask's RAM output. `multiscan` (sys/osd.v ~line 158/211-234) is
# updated only once per frame, inside the same rare
# `if(h_cnt > {dsp_width,2'b00})`-gated block that already justifies the
# osd_vcnt exception above, and is compared every pixel against `osd_div`
# (`if(osd_div == multiscan)`) the same way pixsz/pixcnt are -- by the time
# osd_div reaches multiscan's value, multiscan has been stable for a whole
# frame. Same class of signal, same justification; the multicycle relax is
# on the destination register so it covers both incoming sources.
set_multicycle_path -to {*_osd|multiscan*} -setup 2
set_multicycle_path -to {*_osd|multiscan*} -hold 1

# core specific constraints

# The forwarded SDRAM clock, the CPU clock-enable exception, and the sprite
# state-exclusive exception all reference objects (PLL divider pins, fitted
# registers) that do not exist during analysis & synthesis.  The previous hard
# `error` guards fired at the quartus_map stage and silently disabled
# timing-driven synthesis (audit R20 PF-5).  Defer the dependent constraints
# with a warning during synthesis; still fail hard once the fitter/STA netlist
# must contain them.
proc s32_require {present what} {
    if {$present} { return 1 }
    if {[string match "quartus_map" $::quartus(nameofexecutable)]} {
        post_message -type warning \
            "s32 SDC: $what not elaborated yet; deferring to fit/STA"
        return 0
    }
    error "s32 SDC: expected $what but it is missing at $::quartus(nameofexecutable)"
}

#**************************************************************
# Sega System 32 core: SDRAM timing (CL2 @ 96.634615 MHz, 180deg clock)
#**************************************************************
set sdram_fwd_pin [get_pins -nowarn -compatibility_mode \
    {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set sdram_mem_clk [get_clocks -nowarn \
    {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}]

if {[s32_require [expr {[get_collection_size $sdram_fwd_pin] == 1 && \
                        [get_collection_size $sdram_mem_clk] == 1}] \
        "exactly one PLL outclk2 pin and outclk0 clock for the SDRAM bus"]} {

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

}

# 2026-08-05: CPU Turbo was retired from the single merged s32 profile (see
# memory s32-single-profile-roadmap) specifically so this fixed-CE assumption
# can apply unconditionally. Every board now runs a fixed per-game cadence
# (Arcade-SegaSystem32.sv's cpu_ce_inc) with no Turbo multiplier, so every
# board leaves at least one idle clk_sys edge between V60 updates and this
# revision's internal V60 register paths have a real two-cycle requirement
# universally -- there is no longer a second, single-cycle-timed revision.
set v60_regs [get_registers -nowarn {*|s32_v60:v60|*}]
if {[s32_require [expr {[get_collection_size $v60_regs] > 0}] "V60 registers for the fixed-CE constraint"]} {
    set_multicycle_path -setup 2 -from $v60_regs -to $v60_regs
    set_multicycle_path -hold 1 -from $v60_regs -to $v60_regs

    # Every merged-profile build retains the optional FP state machine now
    # (S32_V60_NO_FP is no longer defined anywhere), so fp_a registers are
    # always expected; absence would indicate that macro reappeared.
    set v60_fp_a [get_registers -nowarn {*|s32_v60:v60|fp_a[*]}]
    if {[get_collection_size $v60_fp_a] > 0} {
        set_multicycle_path -setup 3 -from $v60_fp_a -to $v60_regs
        set_multicycle_path -hold 2 -from $v60_fp_a -to $v60_regs
    } else {
        post_message -type info "s32 SDC: no fp_a registers found (unexpected unless S32_V60_NO_FP is defined)"
    }
}
# Sprite words 0..6 are loaded at least two fetch clocks before decode; word 7
# is intentionally excluded because clip commands consume it on the very next
# decode edge.  x0/y0 are latched before the scale/row/pixel states consume
# them.  These paths are state-exclusive, while the sprite FSM still accepts
# and emits one pixel per fast clock in R_PIXEL.  A two-cycle requirement
# describes the minimum real separation without reducing renderer throughput.
set sprite_deferred_sources [get_registers -nowarn \
    {*|s32_sprite:sprite|sw[0][*] *|s32_sprite:sprite|sw[1][*] \
     *|s32_sprite:sprite|sw[2][*] *|s32_sprite:sprite|sw[3][*] \
     *|s32_sprite:sprite|sw[4][*] *|s32_sprite:sprite|sw[5][*] \
     *|s32_sprite:sprite|sw[6][*] *|s32_sprite:sprite|x0[*] \
     *|s32_sprite:sprite|y0[*]}]
set sprite_regs [get_registers -nowarn {*|s32_sprite:sprite|*}]
if {[s32_require [expr {[get_collection_size $sprite_deferred_sources] > 0 && \
                        [get_collection_size $sprite_regs] > 0}] \
        "sprite registers for the state-exclusive timing constraint"]} {
    set_multicycle_path -setup 2 -from $sprite_deferred_sources -to $sprite_regs
    set_multicycle_path -hold  1 -from $sprite_deferred_sources -to $sprite_regs
}

# The NEC V25 (s80x86) runs on clk_v25 = outclk3 (clk_sys/2, 24.158653 MHz) so its
# large core meets timing with real margin.  Its two crossings to the clk_sys/
# clk_ram world -- the SDRAM p5 line fetch and the V60-side mailbox port -- are
# handled in RTL by two-flop toggle synchronisers (s32_v25_cpu) and a true-dual-
# port RAM, so STA must NOT time those paths.  Declaring clk_v25 asynchronous to
# the rest false-paths them.  The universal build instantiates the block and
# descriptors decide whether a game uses it; detect the instance before adding
# the clock group so source-only simulation remains unaffected.
set v25_regs [get_registers -nowarn {*|s32_v25_cpu:v25|*}]
if {[get_collection_size $v25_regs] > 0} {
    set v25_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[3].*|divclk}]
    if {[s32_require [expr {[get_collection_size $v25_clk] == 1}] \
            "clk_v25 PLL output clock for the asynchronous clock group"]} {
        set_clock_groups -asynchronous -group $v25_clk
    }
}
