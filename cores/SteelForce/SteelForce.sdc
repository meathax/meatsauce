derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ---------------------------------------------------------------------------
# SDRAM external interface (MiSTer SDRAM module, SDR, CL2, burst 4, one clock).
#
# Clock: rtl/steel_pll.sv outclk1 (general[1], 45.6 MHz, +5482 ps = 90 deg to
# clk_sys) drives the SDRAM_CLK pin through altddio_out (datain_h=1, datain_l=0,
# SteelForce.sv), so the pad is NOT inverted. The generated clock is anchored on
# the PLL output counter so TimeQuest includes the real source-to-pin path of the
# forwarded clock (PLL output -> clock network -> IO buffer). Do not add the PLL
# phase again to any delay below.
#
# Device envelope (AS4C32M16SB-7 at CL2, which also bounds the 32 MB Winbond
# W9825G6KH-6 module; same contract as cores/darkmist/constraints/external-final/
# base-r4.sdc, Alliance Rev 1.4 June 2024 Table 16 / Figure 20 as recorded there):
#   tAC max 6.0 ns (clock to data valid), tOH min 2.5 ns (data hold),
#   tIS 1.5 ns (command/address/data/DQM setup), tIH 0.8 ns (hold).
# Board allowance (module connector, FPGA package to pad, chip pads; not measured
# on this board, the established bound used by sibling cores):
#   FPGA clock pad -> SDRAM clock pad flight: 0.0 .. 1.5 ns
#   each data/command pad flight, either direction: 0.0 .. 1.5 ns
#
# Read (SDRAM -> FPGA): data leaves the chip tAC (max) after the clock edge it saw;
#   clock flight and data flight add. Input delay is the sum, relative to the pad
#   clock edge:
#     max = ck_flight_max + tAC_max + data_flight_max = 1.5 + 6.0 + 1.5 = 9.0 ns
#     min = ck_flight_min + tOH_min + data_flight_min = 0.0 + 2.5 + 0.0 = 2.5 ns
# Write (FPGA -> SDRAM): output delay is the chip requirement relative to the pad
#   clock edge, corrected for the clock/data flight difference:
#     max =  tIS + data_flight_max - ck_flight_min =  1.5 + 1.5 - 0.0 =  3.0 ns
#     min = -tIH + data_flight_min - ck_flight_max = -0.8 + 0.0 - 1.5 = -2.3 ns
# No -invert, multicycle, false path or clock-group exception is used. The RTL edge
# schedule equals TimeQuest's default single-cycle relation (sim/sdram_pin_model.hpp,
# steel_sdram_chip.sv): commandReg changes on board edge E0 and the chip registers
# it on the first pad edge after E0; for CL2 the chip drives beat 0 after pad edge
# P1 and doutReg captures it on the next board edge E2 (launch P1 -> capture E2, the
# default read relation); the command is captured by the first pad edge after the
# board edge that launched it (default write relation). Read and write both depend
# on the pad-clock phase: read slack falls and write slack rises 1 ns per ns of PLL
# phase, so the phase window is [phi_write_min, phi_read_max] (see the fit report).
# ---------------------------------------------------------------------------
set sf_sd_master {}
foreach_in_collection sf_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|*|divclk}] {
    set sf_name [get_clock_info -name $sf_clk]
    if {[regexp {general\[1\]\.gpll~PLL_OUTPUT_COUNTER\|divclk$} $sf_name]} {
        lappend sf_sd_master $sf_name
    }
}
if {[llength $sf_sd_master] != 1} {
    error "SteelForce: SDRAM_CLK source must resolve to exactly one PLL outclk1 clock, found: $sf_sd_master"
}
set sf_sd_src [get_pins -compatibility_mode [lindex $sf_sd_master 0]]
if {[get_collection_size $sf_sd_src] != 1} {
    error "SteelForce: SDRAM_CLK source pin must resolve once"
}
create_generated_clock -name SF_SDRAM_CLK -source $sf_sd_src -divide_by 1 [get_ports {SDRAM_CLK}]

set sf_sd_dq   [get_ports {SDRAM_DQ[*]}]
set sf_sd_outs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $sf_sd_dq] != 16 || [get_collection_size $sf_sd_outs] != 38} {
    error "SteelForce: SDRAM port closure incomplete"
}
set sf_ck_min 0.0
set sf_ck_max 1.5
set sf_data_min 0.0
set sf_data_max 1.5
set sf_tac_max 6.0
set sf_toh_min 2.5
set sf_tis 1.5
set sf_tih 0.8
set_input_delay  -clock SF_SDRAM_CLK -max [expr {$sf_ck_max+$sf_tac_max+$sf_data_max}] $sf_sd_dq
set_input_delay  -clock SF_SDRAM_CLK -min [expr {$sf_ck_min+$sf_toh_min+$sf_data_min}] $sf_sd_dq
set_output_delay -clock SF_SDRAM_CLK -max [expr {$sf_tis+$sf_data_max-$sf_ck_min}] $sf_sd_outs
set_output_delay -clock SF_SDRAM_CLK -min [expr {-$sf_tih+$sf_data_min-$sf_ck_max}] $sf_sd_outs
