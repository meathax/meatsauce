derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# Physical SDRAM interface; AS4C32M16SB-7 CL2 budget, analysed at both runtime PLL settings (96 MHz late family and
# 93.8 MHz early family; the 93.8 MHz PLL clocks are created in SNK_TripleZ80.physical.sdc). SDRAM clock = 1x clk_sys.
# Datasheet tAC=6.0, tOH=2.5, tIS=1.5, tIH=0.8 ns.
# Design bounds (not measured): return-clock+data flight <=1.0 ns,
# output data/clock differential skew +/-0.3 ns. Module/load/slew
# compatibility and these bounds remain a final physical gate.
# The actual controller DDIO datain_h=0/datain_l=1 inverts outclk_1.
# Runtime family PLL (rtl/snk/clock/snk_pll_mode.sv): derive_pll_clocks gives the power-up 96 MHz setting (K 9.6). The
# 13.4 MHz family rewrites only K to 9.38: VCO 469 MHz, both outputs 93.8 MHz, C1 phase unchanged (54 deg). This file is read
# BEFORE SNK_TripleZ80.physical.sdc, so the 93.8 MHz clocks are created here and the physical file only uses them.
set snk_sys_938 SNK_SYS_938
set snk_sdr_938 SNK_SDR_938
set snk_pll_pins [list \
    c0src {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|vco0ph[0]} \
    c0dst {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} \
    c1src {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|vco0ph[0]} \
    c1dst {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}]
foreach {key name} $snk_pll_pins {
    set snk_p_$key [get_pins -compatibility_mode [list $name]]
    if {[get_collection_size [set snk_p_$key]] != 1} {error "SNK 93.8 MHz PLL pin $key unresolved"}
}
# Derived straight from the 96 MHz setting's VCO clock (480 MHz): x469/2400 = 93.8 MHz exactly. A second VCO clock on the same pin
# made the derived counter clocks ambiguous (Illegal Clocks), so there is one master clock per PLL pin.
set snk_vco96 {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|fpll_0|fpll|vcoph[0]}
create_generated_clock -name SNK_SYS_938 -master_clock $snk_vco96 -source $snk_p_c0src -multiply_by 469 -divide_by 2400 -add $snk_p_c0dst
create_generated_clock -name SNK_SDR_938 -master_clock $snk_vco96 -source $snk_p_c1src -multiply_by 469 -divide_by 2400 -phase 54 -add $snk_p_c1dst
# Same domain cuts sys_top.sdc applies to the 96 MHz emu clocks (those were read before these clocks existed).
set_clock_groups -exclusive \
   -group [get_clocks {SNK_SYS_938 SNK_SDR_938}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { spi_sck}] \
   -group [get_clocks { hdmi_sck}] \
   -group [get_clocks { *|h2f_user0_clk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]
set snk_sdram_src [get_pins {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}]
if {[get_collection_size $snk_sdram_src] != 1} {
    error {SNK SDRAM forwarded PLL source must resolve to exactly one pin}
}
create_generated_clock -name SNK_SDRAM_CLK -master_clock {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk} -source $snk_sdram_src -divide_by 1 -invert [get_ports SDRAM_CLK]
create_generated_clock -name SNK_SDRAM_CLK_938 -master_clock $snk_sdr_938 -source $snk_sdram_src -divide_by 1 -invert -add [get_ports SDRAM_CLK]
set snk_sdram_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE}]
foreach snk_sdram_clk {SNK_SDRAM_CLK SNK_SDRAM_CLK_938} {
    set_output_delay -clock $snk_sdram_clk -max 1.8 -add_delay $snk_sdram_outputs
    set_output_delay -clock $snk_sdram_clk -min -1.1 -add_delay $snk_sdram_outputs
    set_input_delay -clock $snk_sdram_clk -max 7.0 -add_delay [get_ports {SDRAM_DQ[*]}]
    set_input_delay -clock $snk_sdram_clk -min 2.5 -add_delay [get_ports {SDRAM_DQ[*]}]
}
# The 96 MHz / 93.8 MHz clock sets are physically exclusive (one K at a time); that group is declared at the end of
# SNK_TripleZ80.physical.sdc, after the HDMI direct clocks exist.
derive_clock_uncertainty

# The controller samples SDRAM_DQ into the raw, enable-free dq_in bank (I/O-cell packed);
# dout/dout_next are loaded from dq_in one clock later on the same clock.
# Collect the exact physical names, including fitter clones.
set snk_capture_dq [get_ports {SDRAM_DQ[*]}]
set snk_capture_names {}
set snk_capture_basebits {}
foreach_in_collection snk_capture_reg [get_registers -nowarn {*dq_in*}] {
    set snk_capture_name [get_register_info -name $snk_capture_reg]
    if {![string match {*|snk_union_rom_bridge:roms|snk_rom_store:store|snk_sdram:controller|*} $snk_capture_name]} {continue}
    if {[regexp {\|snk_sdram:controller\|dq_in\[([0-9]+)\](~DUPLICATE[0-9]*)?$} $snk_capture_name -> snk_capture_bit snk_capture_clone]} {
        if {$snk_capture_bit>=16} {error {Unexpected SDRAM logical capture width}}
        if {$snk_capture_clone eq ""} {lappend snk_capture_basebits $snk_capture_bit}
        lappend snk_capture_names $snk_capture_name
    }
}
set snk_read_captures [get_registers -nowarn $snk_capture_names]
set snk_capture_expected_bits {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}
if {[get_collection_size $snk_capture_dq] != 16 ||
    [lsort -integer -unique $snk_capture_basebits] ne $snk_capture_expected_bits ||
    [get_collection_size $snk_read_captures] < 16 ||
    [get_collection_size [get_clocks -nowarn SNK_SDRAM_CLK]] != 1 ||
    [get_collection_size [get_clocks -nowarn SNK_SDRAM_CLK_938]] != 1} {
    error {SNK physical DQ/logical capture coverage/clock missing or ambiguous}
}
# The SDRAM clock edge that launches a read beat reaches dq_in two internal clock edges later
# (same relationship as before the dq_in stage). No hold1 override: retain the NEXT producer
# beat hold check for original bits and their clones.
set_multicycle_path -setup -end 2 -from $snk_capture_dq -to $snk_read_captures

# Z80 core clock-enable multicycle (96MHz master, plan M1; mister-clock-timing.md section 3).
# Proof: every flop in the converted t80 core (u0) takes its next value through its `cen` mux or register-file
# write enable; `cen` = CEN_p & ~cen_pol so consecutive u0 enables are at least one CEN_p period apart
# (late 24 clocks by construction; Guerrilla War A/B snk_late_boost_cen >= 12 in every OSD speed and across live mode
# switches/reset, sim/gwar_speed/tb_gwar_boost_cen.sv; early family at 93.8 MHz >= guard MIN_SPACING 11..46 (27 for the
# game Z80s, 23 for 4 MHz; sim/pll_family/tb_early_ce_938.sv); pause/stall only widens). A launch therefore has
# at least 11 clocks before the next u0 update; two clocks are used. The single non-gated flop (n2126_q, NMI
# edge detector) is excluded from -from. Capture side is u0 itself and the program-bank ROM address
# registers, which the CPU consumes only on a later enable. Re-prove if cen spacing, MIN_SPACING or
# the T80 netlist changes.
set snk_t80_u0 [get_registers -nowarn {*|T80pa:cpu[*].processor|aso_t80pa_native:native_cpu|t80_*:u0|*}]
set snk_t80_nmi [get_registers -nowarn {*|T80pa:cpu[*].processor|aso_t80pa_native:native_cpu|t80_*:u0|n2126_q*}]
set snk_t80_pb [get_registers -nowarn {*snk_union_program_bank:program_bank|*}]
if {[get_collection_size $snk_t80_u0] < 100 || [get_collection_size $snk_t80_nmi] < 1} {
    error {SNK T80 core registers missing or NMI exclusion unresolved}
}
# The 7 wrapper flops of aso_t80pa_native (n186..n192_q: DI/wait/interrupt input registers) also update only through
# CEN_p/CEN_n-qualified enables (checked structurally from the netlist) and are included on both sides.
# 2026-10-22: the pattern now ends n*_q* so the bit-selected vector wrapper flops (n186_q[1:0] intcycled_n, n187_q[7:0] di_reg)
# are included; `n*_q` matched only the five scalar flops, leaving di_reg paths single-cycle (r42: 40 paths -1.737ns, STA relationship 10.329).
set snk_t80_wrap [get_registers -nowarn {*|T80pa:cpu[*].processor|aso_t80pa_native:native_cpu|n*_q*}]
if {[get_collection_size $snk_t80_wrap] < 7} {
    error {SNK T80 wrapper registers unresolved}
}
set snk_t80_from [add_to_collection [remove_from_collection $snk_t80_u0 $snk_t80_nmi] $snk_t80_wrap]
set snk_t80_to [add_to_collection [add_to_collection $snk_t80_u0 $snk_t80_pb] $snk_t80_wrap]
set_multicycle_path -setup -end 2 -from $snk_t80_from -to $snk_t80_to
set_multicycle_path -hold -end 1 -from $snk_t80_from -to $snk_t80_to

# Download profile register. It changes only on a profile header write or reset, and in the same clock edge
# need_rom is set; need_rom is part of bridge_reset/reset_game, which holds every downstream consumer in reset
# until a complete ordered ROM stream has been accepted (>= hundreds of thousands of clocks). The first ROM byte
# is also separated from the header by the HPS transfer cadence (tens of clocks). All consumers therefore
# observe a settled profile; the 1-2 clock transient at the change is flushed by the reset/download that follows.
# Re-prove if need_rom/bridge_reset composition or the guard's profile update conditions change.
set snk_profile_regs [get_registers -nowarn {*|snk_rom_download_guard:download_guard|profile* *|snk_profile_hiscore:high_scores|current_profile*}]
if {[get_collection_size $snk_profile_regs] < 8} {
    error {SNK profile register collection unresolved}
}
set_false_path -from $snk_profile_regs

# hps_io ioctl_index is written only by the FIO_FILE_INDEX command word (sys/hps_io.sv:665), a separate SPI command
# from FIO_FILE_TX/TX_DAT, so it is stable for many clocks before ioctl_download rises and for the whole transfer.
# Two-clock setup / one-clock hold from the register is therefore safe for all consumers.
set snk_ioctl_index [get_registers -nowarn {*|hps_io:hps_io|ioctl_index*}]
if {[get_collection_size $snk_ioctl_index] < 16} {
    error {SNK ioctl_index registers unresolved}
}
set_multicycle_path -setup -end 2 -from $snk_ioctl_index
set_multicycle_path -hold -end 1 -from $snk_ioctl_index

# Early controller register file. bg_x/fg_x/sprite_x/bg_y/fg_y/sprite_y/sprite_split (wave) and the HSJ controller bg_y
# are written only by the CPU write decode (`case(addr) ...<=data` in snk_wave_controller_external / the HSJ
# controller), i.e. at most once per CPU enable (>= 24 clocks apart) and asynchronously to the pixel/FCK engine,
# exactly as on the board. A consumer therefore never needs the new value within a single clock; two-clock setup /
# one-clock hold from these registers is safe.
set snk_early_cfg [get_registers -nowarn {*|snk_wave_controller_external:wave|sprite_* *|snk_wave_controller_external:wave|bg_* *|snk_wave_controller_external:wave|fg_* *|snk_early_hsj_controller:hsj|bg_y* *|snk_early_hsj_controller:hsj|bg_x* *|snk_early_hsj_controller:hsj|sprite_*}]
if {[get_collection_size $snk_early_cfg] < 40} {
    error {SNK early controller configuration registers unresolved}
}
set_multicycle_path -setup -end 2 -from $snk_early_cfg
set_multicycle_path -hold -end 1 -from $snk_early_cfg

# reset_game_r fans into full-rate RAM write/HS admission and CPU input muxes.
# Early CEs keep running during reset, so release has no guaranteed CE-free window.
# Keep reset distribution and every downstream transfer single-cycle timed.

# Pinned Template Y/C carrier modulation is full-rate, including the LUT reference
# and phase[2] product registers (sys/yc_out.sv:157-171,214-215). A1's ordinary
# 96 MHz check failed by 0.174 ns at slow -40C. Steer these exact paths with a
# stricter 9.8 ns max delay (96 MHz period 10.416667 ns); no clock/hold relaxation.
# Include all LUT names because synthesis merges low SIN/COS bits with shared LUTs.
set snk_yc_lut [get_registers -nowarn {yc_out:yc_out|chroma_LUT*}]
set snk_yc_product_names {}
foreach_in_collection snk_yc_reg [get_registers -nowarn {yc_out:yc_out|*}] {
    set snk_yc_name [get_register_info -name $snk_yc_reg]
    if {[regexp {^yc_out:yc_out\|phase\[2\]\.[uv]\[[0-9]+\](~DUPLICATE[0-9]*)?$} $snk_yc_name]} {
        lappend snk_yc_product_names $snk_yc_name
    }
}
set snk_yc_product [get_registers -nowarn $snk_yc_product_names]
if {[get_collection_size $snk_yc_lut] < 8 || [get_collection_size $snk_yc_product] < 16} {
    error {SNK full-rate Y/C LUT/product steering endpoints unresolved}
}
# The only active carrier clocks are these physically-exclusive runtime modes.
# Require the steering target to be strictly tighter than each ordinary period.
foreach snk_yc_clock_name [list {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} SNK_SYS_938] {
    set snk_yc_clock [get_clocks -nowarn [list $snk_yc_clock_name]]
    if {[get_collection_size $snk_yc_clock] != 1} {error {SNK Y/C steering clock unresolved}}
    foreach_in_collection snk_yc_clock_id $snk_yc_clock {
        if {[get_clock_info -period $snk_yc_clock_id] <= 10.350} {
            error {SNK Y/C steering target no longer tighter than ordinary period}
        }
    }
}
# Optimization target only: native full-single-cycle all8 proof passes both runtime modes.
# 10.350ns remains stricter than native 10.417/10.661ns relationships on every retained YC path.
# Final STA reuses the unchanged graph fitted under 9.300ns; no clock/multicycle/false-path relaxation.
set_max_delay -from $snk_yc_lut -to $snk_yc_product 10.350

# Late ROM download decode. ld_addr_q/ld_data_q load only on an accepted byte and are then held until the next accepted
# byte; load_wait stays high for the strobe stages (ld_wr_q, ld_wr_qq, ld2_wr_q) and the bridge, so the next accept is
# at least 4 clocks later. The decode strobe (ld_wr_qq) is one clock behind the held address/data, so the decode
# result is sampled by ld2_* no earlier than two clocks after the held values change.
set snk_ld_src [get_registers -nowarn {*|ld_addr_q* *|ld_data_q*}]
set snk_ld_dst [get_registers -nowarn {*|ld2_addr_q* *|ld2_data_q* *|ld2_wr_q* *|board_load_addr* *|board_load_data* *|board_rom_wr*}]
if {[get_collection_size $snk_ld_src] < 33 || [get_collection_size $snk_ld_dst] < 68} {
    error {SNK late-load staging registers unresolved}
}
set_multicycle_path -setup -end 2 -from $snk_ld_src -to $snk_ld_dst
set_multicycle_path -hold -end 1 -from $snk_ld_src -to $snk_ld_dst

# Hiscore address register. hs_req is qualified by request_pending_d (snk_profile_hiscore.sv), and the FSM acts only
# on hs_req && hs_ack, so no response derived from a new hs_addr is consumed earlier than two clocks after it changes
# (launch edge -> request_pending_d edge -> hs_req/ack sampled). Two-clock setup / one-clock hold from hs_addr is safe.
set snk_hs_addr [get_registers -nowarn {*|snk_profile_hiscore:high_scores|hs_addr*}]
if {[get_collection_size $snk_hs_addr] < 16} {
    error {SNK hiscore hs_addr registers unresolved}
}
set_multicycle_path -setup -end 2 -from $snk_hs_addr
set_multicycle_path -hold -end 1 -from $snk_hs_addr

# JTOPL/Y8950 FM datapath: every non-bus register in psychos_jtopl_* updates only on cen/cenop (cenop = one
# per four chip clocks via psychos_jtopl_div, chip clock >= 23 clocks apart at either PLL setting), except the CPU-bus register file
# (mmr), the divider and timers, which are excluded from -from.
set snk_opl_all [get_registers -nowarn {*|psychos_jtopl_*:*|* *|snk_late_jtopl*:*|*}]
set snk_opl_top [get_registers -nowarn {*|psychos_jtopl:*|*}]
# (mmr config registers change only on CPU writes and are quasi-static against the operator cycle, so they stay
# in -from; only the free-running divider/timers/csr are excluded.)
# (psychos_jtopl_csr only instantiates psychos_jtopl_sh_rst shifters, which load under `if(cen)`, so csr stays in.)
set snk_opl_bus [get_registers -nowarn {*|psychos_jtopl_div:*|* *|psychos_jtopl_timers:*|*}]
set snk_opl_regs [add_to_collection $snk_opl_all $snk_opl_top]
if {[get_collection_size $snk_opl_regs] < 100} {
    error {SNK JTOPL register collection unresolved}
}
set snk_opl_from [remove_from_collection $snk_opl_regs $snk_opl_bus]
set_multicycle_path -setup -end 2 -from $snk_opl_from -to $snk_opl_regs
set_multicycle_path -hold -end 1 -from $snk_opl_from -to $snk_opl_regs
