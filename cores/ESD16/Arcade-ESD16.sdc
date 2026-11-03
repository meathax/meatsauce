derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# SDRAM_CLK: PLL outclk_1 (98 MHz, phase per rtl/pll/pll_0002.v) forwarded through the inverted altddio_out
# in ESD16.sv, so the pin clock is outclk_1 inverted plus IOE delay. sys_top.sdc already holds emu|pll|pll_inst
# outputs in one synchronous clock group. CAS3 schedule: READ sampled on the first SDRAM edge after launch,
# first beat captured at controller C4 (two clk_sys edges after its SDRAM launch edge, see multicycle below).
# This source still requires its own fitted timing; hardware is unqualified.
# ---------------------------------------------------------------------------
set esd_sdram_pin [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $esd_sdram_pin] != 1} {
    error "ESD16 requires exactly one SDRAM forwarding PLL output (general[1])"
}
create_generated_clock -name SDRAM_CLK -source $esd_sdram_pin -divide_by 1 -invert [get_ports {SDRAM_CLK}]

# Bounded standard-module envelope at 98 MHz CL3: DQ input 2.8..6.0 ns = tOH min 2.5 ns + 0.3 ns flight and tAC max 5.4 ns
# + 0.6 ns clock/data round-trip flight (Alliance AS4C16M16SA / Micron MT48LC16M16A2 CL3 rows in standard_modules_p0).
# The flight terms are an assumption for standard short MiSTer SDRAM add-on traces, not a measured board value.
# SDRAM output 2.5/-1.5 ns.
# See standard_modules_p0 and CAS3 transfer receipts; unknown board flight remains outside this qualification.
set esd_dq  [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $esd_dq] != 16} {
    error "ESD16 requires exactly 16 SDRAM_DQ input ports"
}
set esd_out [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
set_input_delay  -clock SDRAM_CLK -max 6.0  $esd_dq
set_input_delay  -clock SDRAM_CLK -min 2.8  $esd_dq

# DQ is captured by IOE input registers (dq_cap) on the phase-shifted PLL outclk_2 and consumed one clk_sys later
# (controller DST = READ + CL3 + CAP_STAGES(2): dq_cap IOE register, dq_cap2 fabric register, then dout). The capture edge is two SDRAM_CLK-launch periods after the READ's
# first beat edge, so the setup relationship carries one extra period; the cap -> clk_sys hop is an ordinary
# same-frequency PLL transfer checked by default setup/hold.
set esd_dout_regs [get_registers {*esd16_sdram*sdram*|dq_cap[*]}]
if {[get_collection_size $esd_dout_regs] != 16} {
    error "ESD16 requires exactly 16 SDRAM DQ capture registers"
}
set_multicycle_path -setup -end 2 -from $esd_dq -to $esd_dout_regs

set_output_delay -clock SDRAM_CLK -max 2.5  $esd_out
set_output_delay -clock SDRAM_CLK -min -1.5 $esd_out

# Single-WRITE data/OE remains stable through the following sysclk edge.
# Qualified physical write/reset proof: sdram_beat_contract_cas3_phase3253_p0.
# Exact fitted family inventory from R11; validate all data bits and OE replicas.
set esd_dq_hold_regs [get_registers {emu:emu|esd16_sdram:sdram|jtframe_sdram64:u_sdram|dq_pad*}]
set esd_dq_data_bits {}
set esd_dq_oe_count 0
foreach_in_collection esd_reg $esd_dq_hold_regs {
    set esd_name [get_node_info -name $esd_reg]
    if {![regexp {^emu:emu\|esd16_sdram:sdram\|jtframe_sdram64:u_sdram\|dq_pad\[([0-9]+)\](~en(_Duplicate_([0-9]+))?)?$} $esd_name esd_whole esd_bit esd_oe esd_dup esd_copy]} {
        error "unclassified SDRAM data/OE register: $esd_name"
    }
    if {$esd_bit < 0 || $esd_bit > 15} {error "SDRAM output bit out of range: $esd_name"}
    if {$esd_oe eq ""} {
        if {[lsearch -exact $esd_dq_data_bits $esd_bit] >= 0} {error "duplicate SDRAM data bit: $esd_name"}
        lappend esd_dq_data_bits $esd_bit
    } else {
        if {$esd_copy ne "" && ($esd_copy < 0 || $esd_copy > 15)} {error "SDRAM OE replica out of range: $esd_name"}
        incr esd_dq_oe_count
    }
}
if {[llength $esd_dq_data_bits] != 16 || $esd_dq_oe_count < 1 || $esd_dq_oe_count > 16 || [get_collection_size $esd_dq_hold_regs] != 16+$esd_dq_oe_count} {
    error "SDRAM output source coverage mismatch"
}
puts "ESD_OUTPUT_HOLD_COVERAGE data=[llength $esd_dq_data_bits] oe=$esd_dq_oe_count total=[get_collection_size $esd_dq_hold_regs]"
set_multicycle_path -hold -start 1 -from $esd_dq_hold_regs -to $esd_dq

# ---------------------------------------------------------------------------
# Z80 sound CPU: register-to-register paths inside the T80s hierarchy only.
# Proof: every sequential block in donors/tumble-tv80 (tv80_core: always at lines 373/879/1041 gated by ClkEn =
# cen && !BusAck, 1113/1158/1192 gated by cen; tv80_reg: if (CEN) with CEN=ClkEn; T80s.v:73 else if (CEN)) changes state
# only on a clk_sys edge where cen_z80 is high; cen_z80 enables are >= 24 clk_sys apart across burst, pause, stall and
# reset (sim/clock/tb_esd16_cen.sv, evidence/ce_98mhz.log; negative ce_98mhz_negative_z80.log). Launch and capture
# therefore both happen on enable edges at least two clk_sys periods apart, so two setup periods (hold unchanged) is exact.
# Paths from outside the Z80 (data bus, WAIT, INT, BUSRQ) and from the Z80 to other logic keep their single-cycle checks.
# ---------------------------------------------------------------------------
set esd_z80_regs [get_registers {emu:emu|esd16_top:game|esd16_sound:u_snd|T80s:u_z80|*}]
if {[get_collection_size $esd_z80_regs] < 100} {
    error "ESD16 Z80 register scope not found (T80s hierarchy)"
}
set_multicycle_path -setup -end 2 -from $esd_z80_regs -to $esd_z80_regs
set_multicycle_path -hold  -end 1 -from $esd_z80_regs -to $esd_z80_regs
