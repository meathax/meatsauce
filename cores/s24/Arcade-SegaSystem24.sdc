# Core clocks are derived from the generated PLL IP.
derive_pll_clocks
derive_clock_uncertainty

# The stock sys_top.sdc core-PLL wildcard expects an instance named "pll".
# This core intentionally names its generated PLL "pll_i", so Quartus 17 does
# not place clk_sys/clk_ram in the framework's exclusive clock groups.  List
# the generated clocks exactly here to prevent false core-audio/video paths
# into the independent framework audio, HDMI, HPS, and board clock domains.
set s24_core_clocks [get_clocks {
    emu|pll_i|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
    emu|pll_i|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk
    emu|pll_i|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk
}]
set_clock_groups -asynchronous \
    -group $s24_core_clocks \
    -group [get_clocks {
        pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk
    }] \
    -group [get_clocks {
        pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
    }] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# ---------------------------------------------------------------------------
# SDRAM board interface.
#
# Nothing in this project or in sys/sys_top.sdc previously created a clock on
# the SDRAM_CLK port, so EVERY SDRAM path -- the pin-to-IOE SDRAM_DQ capture
# into sdram.sv's dq_in, and the whole registered command/address bus -- was
# UNCONSTRAINED and silently excluded from timing analysis.  The comment at
# rtl/mem/sdram.sv:314-319 asserts these paths are covered "under the SDC
# input-delay and multicycle constraints"; they were not.
#
# The interface is source-synchronous.  pll outclk2 is clk_ram phase-shifted
# +5208 ps (rtl/pll/synthesis/submodules/pll_pll_inst.v:37-38) = exactly 180
# degrees at 96 MHz, so relative to the clk_ram edge that registers a command:
#   t=0        command/address launched by clk_ram
#   t=5.208ns  SDRAM samples it (half-period of setup)
#   t=26.04ns  CL2 data launched by SDRAM (2 SDRAM clocks later)
#   t=31.25ns  dq_in samples it (cl_pipe[3], 3 clk_ram cycles after the CAS)
#
# That model is INCOMPLETE, and the earlier claim here that "no multicycle
# exception belongs" was wrong.  It ignores the latency of SDRAM_CLK itself:
# the port is fed from outclk2 through general routing and an output buffer,
# and quartus_sta measures 13.804 ns from the PLL edge to the SDRAM_CLK PIN
# against only 7.988 ns for clk_ram reaching the dq_in capture flop -- a
# 5.29-5.82 ns skew, i.e. more than a full half-period, that the sequence
# above omits.  Once it is included the SDRAM's CL2 word cannot possibly
# arrive before the default single-cycle capture edge, and all 16
# SDRAM_DQ -> dq_in paths report about -9 ns.  Those 16 paths were the
# ENTIRE -142.306 ns TNS of the clk_ram domain and the only failing paths in
# the core; clk_ram's own Fmax is 108.45 MHz against 96.63 MHz required.
#
# The -max input delay is tAC(CL2) plus board flight for the parts on the
# MiSTer 128 MB module.
# SDRAM_CLK is driven directly from PLL outclk2 (general[2]), which the PLL
# already phase-shifts +180 degrees -- see Arcade-SegaSystem24.sv. An
# IOE-DDR-forwarded alternative was hardware-tested and reverted after it
# regressed sprite rendering on real hardware (see rtl/mem/sdram.sv's dq_in
# capture comment); source the generated clock from outclk2 directly again,
# with no additional inversion.
set s24_sdram_src [get_pins -nowarn \
    {emu|pll_i|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $s24_sdram_src] > 0 && \
    [get_collection_size [get_ports -nowarn {SDRAM_CLK}]] > 0} {
    create_generated_clock -name SDRAM_CLK -source $s24_sdram_src \
        [get_ports {SDRAM_CLK}]

    set s24_sdram_out [get_ports -nowarn {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
        SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS \
        SDRAM_CKE}]
    set s24_sdram_in  [get_ports -nowarn {SDRAM_DQ[*]}]

    set_output_delay -clock SDRAM_CLK -max  1.5 $s24_sdram_out
    set_output_delay -clock SDRAM_CLK -min -0.8 $s24_sdram_out
    set_input_delay  -clock SDRAM_CLK -max  6.0 $s24_sdram_in
    set_input_delay  -clock SDRAM_CLK -min  2.5 $s24_sdram_in

    # The RTL already waits the extra cycle the forwarding skew demands:
    # cl_pipe[0] is set at the CAS and the capture happens on cl_pipe[3],
    # three clk_ram cycles later -- one cycle MORE than a CL2 read needs.
    # Declaring that to STA describes what the hardware already does; it does
    # not relax a real requirement.  Measured effect: worst setup on
    # SDRAM_DQ -> dq_in goes -9.062 -> +1.286 ns (Slow 100C) and the clk_ram
    # domain TNS to 0.000, while -hold -end 1 keeps the hold check on its
    # original edge (+11.211 ns Slow / +9.277 ns Fast, both unchanged).
    #
    # Do NOT re-reference the input delay to a virtual clock instead: that was
    # measured too and is wrong -- it credits the design with the internal
    # clock insertion delay as if the SDRAM saw the internal clock, giving a
    # physically bogus +7.988 ns skew and a VIOLATED -0.304 ns hold.
    set s24_dq_capture [get_registers -nowarn {*sdram:*|dq_in[*]}]
    if {[get_collection_size $s24_dq_capture] > 0} {
        set_multicycle_path -setup -end 2 -from $s24_sdram_in -to $s24_dq_capture
        set_multicycle_path -hold  -end 1 -from $s24_sdram_in -to $s24_dq_capture
    } else {
        post_message -type critical_warning \
            "SDRAM dq_in capture registers not found; DQ capture left single-cycle"
    }
} else {
    post_message -type critical_warning \
        "SDRAM_CLK generated clock not created; the SDRAM interface is UNCONSTRAINED"
}

# fx68k architectural state advances only on alternating 20 MHz phase enables
# inside clk_sys. Do not add false paths: DTACK and bus decode remain timed in
# the parent clock domain.

# s24_sdram_cdc bundled-data payloads.
#
# clk_sys and clk_ram are PLL-related and deliberately share one clock group
# above, so every payload bit between them is otherwise analysed as an ordinary
# single-cycle synchronous path. The payload registers are NOT single-cycle:
# rtl/mem/s24_sdram_cdc.sv writes req_hold/rsp_hold on the same edge that
# flips its req_toggle/rsp_toggle, and the opposite domain only samples the
# payload one clock AFTER it has observed that toggle through its synchroniser.
# The core instantiates the crossing at SYNC_STAGES(1) because the two clocks
# are an exact phase-locked 2:1 pair (VCO/26 and VCO/13), which puts the
# capture two destination-clock periods after the write in both directions:
#   request  launch clk_sys t=0      -> req_sync_m t=10.348 -> capture t=20.696
#   response launch clk_ram t=10.348 -> rsp_sync_m t=20.696 -> capture t=41.392
# i.e. 2 x 10.348 ns against clk_ram and 31.044 ns against clk_sys, exactly the
# windows the -setup -end 2 below asks for. The payload is therefore provably
# stable for at least two destination-clock periods before any capture, and is
# held until the transaction completes because the producer is gated by
# src_busy/dst_busy. Dropping to SYNC_STAGES(0) would halve both windows and
# make this exception a lie -- see that module's SYNC_STAGES comment.
#
# Without this exception the fitter inserted >2.3 us of hold-fixing routing
# delay across these buses (notably the 128-bit cdc_p2 sprite response),
# exhausted routing in that region, and still missed hold. That is a
# constraint defect, not a placement problem: seeds 3, 5 and 6 all failed the
# same way.
#
# Scope is exactly the bundled payload registers -- the toggle bits, the
# synchroniser registers, the handshake/busy flags and every other path stay
# fully timed, so the crossing's correctness still rests on the handshake
# rather than on this exception.
# Constrain these as MULTICYCLE, never false_path. The payload is genuinely
# relaxed -- but it is NOT unconstrained, and the difference matters on
# silicon. set_false_path removes every bound, so at this design's ~87%
# ALM / 86% RAM congestion the router is free to leave a payload bit
# arbitrarily slow; any bit that misses its capture edge returns corrupt
# read data, which shows up as garbage tile/sprite texture while simpler
# screens still look correct. Verilator has no routing delay and therefore
# cannot reproduce it. A hold violation on the same registers corrupts the
# data too, just for the opposite reason, so neither extreme is acceptable.
#
# clk_ram (96.6 MHz) and clk_sys (48.3 MHz) are PLL-related at exactly 2:1,
# and the handshake guarantees the payload holds for at least two
# destination-clock periods before capture (see the analysis above), so a
# 2-cycle setup with the matching 1-cycle hold adjustment is the correct
# requirement: relaxed enough to remove the hold-fixing routing delay,
# strict enough that every bit remains bounded and analysed.
set s24_cdc_payload_dst [get_registers { \
    *s24_sdram_cdc:*|dst_payload[*] \
    *s24_sdram_cdc:*|src_response[*] }]
if {[get_collection_size $s24_cdc_payload_dst] > 0} {
    set_multicycle_path -setup -end 2 -to $s24_cdc_payload_dst
    set_multicycle_path -hold  -end 1 -to $s24_cdc_payload_dst
} else {
        post_message -type critical_warning \
        "s24_sdram_cdc payload collection is empty; check hierarchy names"
}

# Synthetic wheel input is evaluated by combinational shaping logic but its
# architectural state (analog_step/analog_remainder) is only captured when
# the explicit wheel_tick enable is asserted.  Arcade-SegaSystem24.sv sets
# WHEEL_TICK_PERIOD to 840293 clk_sys cycles (~57.5 Hz), so the HPS joystick
# registers are stable for vastly longer than one clk_sys period before the
# destination capture.  The path is therefore a bounded multicycle path, not
# a false/asynchronous path.  Keep the scope to the four connected HPS
# channels and the tick-gated wheel state registers; every continuously
# clocked wheel path remains single-cycle.  The matching hold adjustment
# preserves the original hold edge while setup moves to the next edge.
set s24_wheel_src [get_registers -nowarn \
    {*hps_io:hps|joystick_l_analog_0[*] \
     *hps_io:hps|joystick_l_analog_1[*] \
     *hps_io:hps|joystick_l_analog_2[*] \
     *hps_io:hps|joystick_l_analog_3[*]}]
set s24_wheel_dst [get_registers -nowarn {
    *|wheel0|analog_step[*] *|wheel0|analog_remainder[*] *|wheel0|stick_toggle *|wheel0|stick_active
    *|wheel1|analog_step[*] *|wheel1|analog_remainder[*] *|wheel1|stick_toggle *|wheel1|stick_active
    *|wheel2|analog_step[*] *|wheel2|analog_remainder[*] *|wheel2|stick_toggle *|wheel2|stick_active
    *|wheel3|analog_step[*] *|wheel3|analog_remainder[*] *|wheel3|stick_toggle *|wheel3|stick_active
}]
if {[get_collection_size $s24_wheel_src] > 0 && \
    [get_collection_size $s24_wheel_dst] > 0} {
    set_multicycle_path -setup -end 2 -from $s24_wheel_src -to $s24_wheel_dst
    set_multicycle_path -hold  -end 1 -from $s24_wheel_src -to $s24_wheel_dst
} else {
    post_message -type critical_warning \
        "Wheel analog multicycle collections are empty; wheel paths left single-cycle"
}
