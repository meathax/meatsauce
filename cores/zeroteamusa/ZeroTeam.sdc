# MiSTer framework defines root clocks in sys/sys_top.sdc.
derive_pll_clocks
derive_clock_uncertainty

# V30 EU architecture state only: all listed registers commit in the common
# if (ss_we || srst || ce) block at v30u_eu.sv:3854. Normal execution is CE-gated;
# reset selects restore/default state, and target savestate loading is disabled.
# Production ce_gen has a five-clock minimum between pulses (CE_GAP_MIN, any
# clk_sel, including stalls, pause and reset; the 16 MHz period is six and the
# 19.2 MHz turbo period is five); sim/v30_ce_minimum.cpp exercises that module.
# Use the FIVE-clock setup window and corresponding four-clock hold adjustment.
# This does not relax the separate CE_HALF bus phase or 96MHz paths.
set zt_eu_ce_names {
    al_adjtmp
    al_adjust
    al_bitarm
    al_bitn
    al_eaconst
    al_eaval
    al_op
    al_spent
    al_tmp
    bit_n
    bnd_armed
    brk_arm
    brk_p
    brk_smp
    bus_word
    chg
    count
    dec_q
    ea_pair_rhs
    ea_pair_valid
    ea_residue
    ending
    eu_halted
    first_pop_seen
    ghost_rd_discard
    gpr
    ie_p
    iend_owed
    imm8
    ind
    int_p
    intr_pending
    irq_fast_inta
    irq_halt_entry
    irq_sel_brk
    irq_sel_nmi
    irq_shadow
    ld_b
    ld_byte
    ld_disp
    ld_dlo
    ld_ext
    ld_grpd
    ld_hasrm
    ld_page
    ld_pla
    ld_preread
    ld_ripe_prev
    ld_rm
    lock_pfx
    m_byte
    m_ea
    m_idx
    m_kind
    m_seg
    mode8080
    modrm_reg
    nmi_latch
    nmi_p
    op8
    opc8080
    opc_base
    opc_byte
    opc_from_modrm
    opc_reg
    opc_valid
    opr
    opr_byte
    opr_fresh
    opr_loaded
    pc
    pe_op8
    pe_opc8080
    pe_opc_reg
    pe_pfxcnt
    pend_active
    pend_byte
    pend_io
    pend_off
    pend_seg
    pfxcnt
    poll_pipe
    pop_is_first
    poste
    psw
    r_byte
    r_ea
    r_idx
    r_kind
    r_seg
    rd_age0
    rd_done_cnt
    rd_pending
    rdp0_byte
    rdp1_byte
    rdq0
    rdq0_byte
    rdq1
    rdq1_byte
    rdq_n
    rep_chain
    rep_kind
    rep_pol
    rep_test
    rloop_n
    row_paired
    row_posted
    rowb0
    rowb1
    rowq
    rst_ctr
    seg_override
    seg_ovr
    sign_neg
    sreg
    st
    stat
    suppress_commit
    tmpa
    tmpa_byte
    tmpb
    tmpb_byte
    tmpc
    tmpc_byte
    tsel
    unhalt_pend
    upc_loc
    upc_opc
    upc_page
    wb_byte
    wb_ea
    wb_idx
    wb_kind
    wb_seg
    wr_out
    xop
}
set zt_eu_ce_patterns {}
foreach zt_reg $zt_eu_ce_names {
    lappend zt_eu_ce_patterns [format {*|v30u_eu:u_eu|%s} $zt_reg]
    lappend zt_eu_ce_patterns [format {*|v30u_eu:u_eu|%s[*]*} $zt_reg]
    lappend zt_eu_ce_patterns [format {*|v30u_eu:u_eu|%s~*} $zt_reg]
}
set zt_eu_ce_regs [get_registers -nowarn $zt_eu_ce_patterns]
if {[get_collection_size $zt_eu_ce_regs] < 100} {
    error "ZeroTeam EU timing scope is missing; do not accept this netlist."
}
post_message "ZeroTeam EU CE timing scope: [get_collection_size $zt_eu_ce_regs] registers"
set_multicycle_path -setup 5 -from $zt_eu_ce_regs -to $zt_eu_ce_regs
set_multicycle_path -hold 4 -from $zt_eu_ce_regs -to $zt_eu_ce_regs

# The first microcode table is a pure read-only combinational ROM in RTL.
# dec_addr_next selects next UPC state at the shared EU commit boundary
# (v30u_eu.sv:3844), with opcode/prefetch inputs from the same-CE BIU state.
# Quartus packs registers associated with that CE commit into the RAM.
# Keep a conservative five-clock window within the six-clock CE spacing.
# The scope excludes the second ucrom table, CE_HALF and unrelated consumers.
set zt_ucdecode_regs [get_registers -nowarn {*|v30u_eu:u_eu|v30u_ucrom:u_ucrom|altsyncram:ucdecode_rtl_0|*}]
if {[get_collection_size $zt_ucdecode_regs] == 0} {
    error "ZeroTeam packed microcode decode scope is missing."
}
post_message "ZeroTeam packed decode scope: [get_collection_size $zt_ucdecode_regs] registers"
set_multicycle_path -setup 5 -from $zt_ucdecode_regs -to $zt_eu_ce_regs
set_multicycle_path -hold 4 -from $zt_ucdecode_regs -to $zt_eu_ce_regs

# The packed address registers participate in the same CE commit boundary.
# Include their input and feedback boundaries, retaining the conservative
# five-clock window. The RTL ROM has no independent clock or write process.
set_multicycle_path -setup 5 -from $zt_eu_ce_regs -to $zt_ucdecode_regs
set_multicycle_path -hold 4 -from $zt_eu_ce_regs -to $zt_ucdecode_regs
set_multicycle_path -setup 5 -from $zt_ucdecode_regs -to $zt_ucdecode_regs
set_multicycle_path -hold 4 -from $zt_ucdecode_regs -to $zt_ucdecode_regs

# BIU architectural commits use the SAME ce as EU (v30u_biu.sv:2593).
# These names come only from that shared CE commit process, excluding t1_half2,
# CE_HALF, debug/capture processes, and the fabric-clock bridge.
# last_ube and last_ad_hi/lo have separate reset/restore processes but their
# normal writes also require ce (v30u_biu.sv:2858,2924,2929).
set zt_biu_ce_names {
    last_ube
    last_ad_hi
    last_ad_lo
    r_absorb_ttl
    r_cdage
    r_cmt_addr
    r_cmt_bs
    r_cmt_data
    r_cmt_fetch
    r_cmt_ghost
    r_cmt_halt
    r_cmt_need
    r_cmt_noaddr
    r_cmt_odd
    r_cmt_pn
    r_cmt_prev_fp
    r_cmt_rd_last
    r_cmt_seg
    r_cmt_ube_n
    r_cmt_valid
    r_cmt_was_owed
    r_cmt_wr
    r_cs_r
    r_cur_addr
    r_cur_bs
    r_cur_data
    r_cur_fetch
    r_cur_halt
    r_cur_late_t1
    r_cur_need
    r_cur_noaddr
    r_cur_odd
    r_cur_pn
    r_cur_rd_last
    r_cur_seg
    r_cur_ube_n
    r_cur_wr
    r_dage
    r_done_ctr
    r_done_wr
    r_e_pend
    r_evald
    r_fetch_ptr
    r_flush_eval
    r_g_age
    r_g_bare
    r_g_row_q
    r_g_sp
    r_grn_n
    r_grn_ttl
    r_halt_pending
    r_halted
    r_infl_n
    r_infl_ttl
    r_last_fetch_addr
    r_no_eval
    r_opr_free_p
    r_opr_held
    r_pf_arm
    r_pf_owed
    r_q_cnt
    r_q_head
    r_q_mem
    r_rd_done_p
    r_rd_first_hi
    r_rd_land
    r_rd_val
    r_rd_was_split
    r_ready_prev
    r_rq_addr
    r_rq_bs
    r_rq_data
    r_rq_ghost
    r_rq_last
    r_rq_late
    r_rq_n
    r_rq_need
    r_rq_noaddr
    r_rq_odd
    r_rq_seg
    r_rq_ube
    r_rq_wr
    r_run
    r_sev
    r_slot_accept
    r_slot_busy
    r_suspended
    r_ts
    r_wr_done_p
}
set zt_biu_ce_patterns {}
foreach zt_reg $zt_biu_ce_names {
    lappend zt_biu_ce_patterns [format {*|v30u_biu:u_biu|%s} $zt_reg]
    lappend zt_biu_ce_patterns [format {*|v30u_biu:u_biu|%s[*]*} $zt_reg]
    lappend zt_biu_ce_patterns [format {*|v30u_biu:u_biu|%s~*} $zt_reg]
}
set zt_biu_ce_regs [get_registers -nowarn $zt_biu_ce_patterns]
if {[get_collection_size $zt_biu_ce_regs] < 100} {
    error "ZeroTeam BIU timing scope is missing; do not accept this netlist."
}
post_message "ZeroTeam BIU CE timing scope: [get_collection_size $zt_biu_ce_regs] registers"
set_multicycle_path -setup 5 -from $zt_biu_ce_regs -to $zt_biu_ce_regs
set_multicycle_path -hold 4 -from $zt_biu_ce_regs -to $zt_biu_ce_regs
set_multicycle_path -setup 5 -from $zt_biu_ce_regs -to $zt_eu_ce_regs
set_multicycle_path -hold 4 -from $zt_biu_ce_regs -to $zt_eu_ce_regs
set_multicycle_path -setup 5 -from $zt_eu_ce_regs -to $zt_biu_ce_regs
set_multicycle_path -hold 4 -from $zt_eu_ce_regs -to $zt_biu_ce_regs
set_multicycle_path -setup 5 -from $zt_biu_ce_regs -to $zt_ucdecode_regs
set_multicycle_path -hold 4 -from $zt_biu_ce_regs -to $zt_ucdecode_regs
set_multicycle_path -setup 5 -from $zt_ucdecode_regs -to $zt_biu_ce_regs
set_multicycle_path -hold 4 -from $zt_ucdecode_regs -to $zt_biu_ce_regs

# COP FSM commits at ce_cop, a reset-initialized divide-by-two toggle
# (Raiden2_cop3.sv:355..358,1623..1693). Only registers assigned in the
# ce_cop branch are listed: trigger latches/cache/DDR/CPU bus stay single-cycle.
# cop_status is deliberately excluded: bit 1 is written by the fast CPU bus.
set zt_cop_ce_names {
    abs_x_r
    abs_y_r
    ang62_l
    atan_src_r2
    coll_allow_swap
    coll_max
    coll_min
    cop_angle
    cop_bank_byte
    cop_bank_wr
    cop_dist
    cop_hit_status
    cop_hit_val
    cop_hit_val_stat
    cop_rom_addr
    cop_rom_req
    cordic_i
    cordic_x
    cordic_y
    cordic_z
    dde5_dir
    dde5_div
    dde5_neg
    dde5_offs
    div_den
    div_i
    div_num
    div_q
    div_r
    dma_cnt
    dma_copy80
    dma_copy_gen
    dma_dst
    dma_dst_abs
    dma_mode_lat
    dma_pal_addr
    dma_pal_stage_we
    dma_pal_wdata
    dma_pal_we
    dma_ram_addr
    dma_ram_be
    dma_ram_wdata
    dma_ram_we
    dma_spr_we
    dma_src
    dma_src_byte
    dma_vram_addr
    dma_vram_wdata
    dma_vram_we
    fade_fb_c
    fade_fb_t
    fade_fg_c
    fade_fg_t
    fade_fr_c
    fade_fr_t
    fade_nofade
    fade_out_val
    fade_paldata
    fade_pure
    fade_tgtdata
    fsm
    hb_adr2
    hb_axis3
    hb_dx
    hb_ptr_addr
    hb_size
    latch_dx
    latch_dy
    macro_offset
    math_dx
    math_dy
    mul_acc
    mul_dst_off
    mul_dst_reg
    mul_i
    mul_md
    mul_mr
    mul_off4
    mul_org
    mul_src_off
    mul_src_reg
    mul_sub_org
    sd
    sort_do_swap
    sort_i
    sort_j
    sort_key
    sort_key_a
    sort_key_b
    sort_pass
    sort_swapped
    sort_val
    sort_val_a
    sort_val_b
    sp_flag
    sp_h1
    sp_h2
    sp_px
    sp_py
    sp_src
    sp_visible
    sp_x
    sp_y
    spr_dma_rel_x
    spr_dma_rel_y
    spr_dst1
    spr_info_l
    spr_rom_lat
    spr_src_is_rom
    sqrt_acc
    sqrt_i
    sqrt_radsh
    sqrt_rem34
    tmp32_a
    tmp32_b
    tmp_hi
    tmp_lo
    x_clip_r

}
set zt_cop_ce_patterns {}
foreach zt_reg $zt_cop_ce_names {
    lappend zt_cop_ce_patterns [format {*|Raiden2_cop3:u_cop3|%s} $zt_reg]
    lappend zt_cop_ce_patterns [format {*|Raiden2_cop3:u_cop3|%s[*]*} $zt_reg]
    lappend zt_cop_ce_patterns [format {*|Raiden2_cop3:u_cop3|%s~*} $zt_reg]
}
set zt_cop_ce_regs [get_registers -nowarn $zt_cop_ce_patterns]
if {[get_collection_size $zt_cop_ce_regs] < 100} {
    error "ZeroTeam COP CE timing scope is missing; do not accept this netlist."
}
post_message "ZeroTeam COP CE timing scope: [get_collection_size $zt_cop_ce_regs] registers"
set_multicycle_path -setup 2 -from $zt_cop_ce_regs -to $zt_cop_ce_regs
set_multicycle_path -hold 1 -from $zt_cop_ce_regs -to $zt_cop_ce_regs

# Demultiplexed V30 bus adapter: these state/address/data latches write only
# under ce (v30_bus_demux.sv:324..379); rdata_q, sampled status and the bridge
# are deliberately excluded. This adapter does not capture these at CE_HALF.
set zt_bus_ce_names {t_state lat_type is_read_cycle is_write_cycle inta_prev
                     inta_second be_lat dout_lat addr_lat a0_lat addr_valid}
set zt_bus_ce_patterns {}
foreach zt_reg $zt_bus_ce_names {
    lappend zt_bus_ce_patterns [format {*|v30_bus:u_core|%s} $zt_reg]
    lappend zt_bus_ce_patterns [format {*|v30_bus:u_core|%s[*]*} $zt_reg]
    lappend zt_bus_ce_patterns [format {*|v30_bus:u_core|%s~*} $zt_reg]
}
set zt_bus_ce_regs [get_registers -nowarn $zt_bus_ce_patterns]
if {[get_collection_size $zt_bus_ce_regs] < 20} {
    error "ZeroTeam V30 bus CE timing scope is missing; do not accept this netlist."
}
post_message "ZeroTeam bus CE timing scope: [get_collection_size $zt_bus_ce_regs] registers"
foreach zt_other [list $zt_eu_ce_regs $zt_biu_ce_regs $zt_ucdecode_regs $zt_bus_ce_regs] {
    set_multicycle_path -setup 5 -from $zt_bus_ce_regs -to $zt_other
    set_multicycle_path -hold 4 -from $zt_bus_ce_regs -to $zt_other
    set_multicycle_path -setup 5 -from $zt_other -to $zt_bus_ce_regs
    set_multicycle_path -hold 4 -from $zt_other -to $zt_bus_ce_regs
}

# Normal demux status sampling is gated by ce_pipe[3] (v30_bus_demux.sv:251),
# four fabric clocks after CE. Minimum next CE is five clocks after launch
# (raiden2_ce_gen CE_GAP_MIN): CE -> status has four clocks; status -> next CE
# has one, so that arc stays single-cycle.
# Do not apply this to fast external IRQ/data inputs or to the CE pipe itself.
set zt_bs_phase_names {bs_q ube_n_q}
set zt_bs_phase_patterns {}
foreach zt_reg $zt_bs_phase_names {
    lappend zt_bs_phase_patterns [format {*|v30_bus:u_core|%s} $zt_reg]
    lappend zt_bs_phase_patterns [format {*|v30_bus:u_core|%s[*]*} $zt_reg]
    lappend zt_bs_phase_patterns [format {*|v30_bus:u_core|%s~*} $zt_reg]
}
set zt_bs_phase_regs [get_registers -nowarn $zt_bs_phase_patterns]
if {[get_collection_size $zt_bs_phase_regs] < 3} {
    error "ZeroTeam delayed V30 status timing scope is missing."
}
post_message "ZeroTeam delayed status scope: [get_collection_size $zt_bs_phase_regs] registers"
foreach zt_ce_group [list $zt_eu_ce_regs $zt_biu_ce_regs $zt_ucdecode_regs $zt_bus_ce_regs] {
    set_multicycle_path -setup 4 -from $zt_ce_group -to $zt_bs_phase_regs
    set_multicycle_path -hold 3 -from $zt_ce_group -to $zt_bs_phase_regs
}
set_multicycle_path -setup 5 -from $zt_bs_phase_regs -to $zt_bs_phase_regs
set_multicycle_path -hold 4 -from $zt_bs_phase_regs -to $zt_bs_phase_regs

# Target IRQ is physically captured on CE_HALF at CE+2. The board pending
# register -> sampler remains a single-cycle path; sampler -> next CE has
# >=3 clocks (five-clock CE minimum), and sampler -> delayed status at CE+4
# has two.
set zt_irq_half_regs [get_registers -nowarn {*|cpu_v30_bridge:u_cpu|*irq_half_q*}]
if {[get_collection_size $zt_irq_half_regs] == 0} {
    error "ZeroTeam IRQ half-phase sampler is missing."
}
post_message "ZeroTeam IRQ half-phase scope: [get_collection_size $zt_irq_half_regs] registers"
foreach zt_ce_group [list $zt_eu_ce_regs $zt_biu_ce_regs $zt_ucdecode_regs $zt_bus_ce_regs] {
    set_multicycle_path -setup 3 -from $zt_irq_half_regs -to $zt_ce_group
    set_multicycle_path -hold 2 -from $zt_irq_half_regs -to $zt_ce_group
}
set_multicycle_path -setup 2 -from $zt_irq_half_regs -to $zt_bs_phase_regs
set_multicycle_path -hold 1 -from $zt_irq_half_regs -to $zt_bs_phase_regs

# TV80 IR writes under ClkEn (tv80_core.v:410); register-bank writes use
# that same ClkEn through CEN (tv80_core.v:1019, tv80_reg.v:53).
# Target oscillator is 96MHz * 105/2816, minimum CE gap 26 clocks.
# Use only TWO clocks here; do not relax bus/mailbox, IRQ inputs or other
# fabric-clock sound paths. Both register-bank lanes share this write enable.
set zt_z80_ir_regs [get_registers -nowarn {*|tv80_core:i_tv80_core|IR[*]*}]
set zt_z80_bank_regs [get_registers -nowarn {*|tv80_core:i_tv80_core|tv80_reg:i_reg|RegsH* *|tv80_core:i_tv80_core|tv80_reg:i_reg|RegsL*}]
if {[get_collection_size $zt_z80_ir_regs] < 8 || [get_collection_size $zt_z80_bank_regs] < 64} {
    error "ZeroTeam TV80 IR/register-bank timing scope is missing."
}
post_message "ZeroTeam TV80 IR/bank scopes: [get_collection_size $zt_z80_ir_regs]/[get_collection_size $zt_z80_bank_regs] registers"
set_multicycle_path -setup 2 -from $zt_z80_ir_regs -to $zt_z80_bank_regs
set_multicycle_path -hold 1 -from $zt_z80_ir_regs -to $zt_z80_bank_regs

# Additional TV80 core state writes in explicit ClkEn/cen commit branches.
# All normal clocked writes were enumerated from those branches; the core has
# no falling-clock processes. Keep fast external interfaces outside this scope.
set zt_z80_ce_names {
    A
    ACC
    ALU_Op_r
    Alternate
    Ap
    Arith16_r
    Auto_Wait_t1
    Auto_Wait_t2
    BTR_r
    BusA
    BusAck
    BusB
    BusReq_s
    F
    Fp
    Halt_FF
    I
    INT_s
    IR
    ISet
    IStatus
    IncDecZ
    IntCycle
    IntE_FF1
    IntE_FF2
    NMICycle
    NMI_s
    No_BTR
    Oldnmi_n
    PC
    Pre_XY_F_M
    PreserveC_r
    R
    Read_To_Reg_r
    RegAddrA_r
    RegAddrB_r
    RegAddrC
    RegBusA_r
    SP
    Save_ALU_r
    TmpAddr
    XY_Ind
    XY_State
    Z16_r
    dout
    m1_n
    mcycle
    mcycles
    rfsh_n
    tstate
}
set zt_z80_ce_patterns {}
foreach zt_reg $zt_z80_ce_names {
    lappend zt_z80_ce_patterns [format {*|tv80_core:i_tv80_core|%s} $zt_reg]
    lappend zt_z80_ce_patterns [format {*|tv80_core:i_tv80_core|%s[*]*} $zt_reg]
    lappend zt_z80_ce_patterns [format {*|tv80_core:i_tv80_core|%s~*} $zt_reg]
}
set zt_z80_ce_regs [get_registers -nowarn $zt_z80_ce_patterns]
if {[get_collection_size $zt_z80_ce_regs] < 64} {
    error "ZeroTeam TV80 shared-enable state scope is missing."
}
post_message "ZeroTeam TV80 shared-CE scope: [get_collection_size $zt_z80_ce_regs] registers"
foreach zt_z80_group [list $zt_z80_ce_regs $zt_z80_bank_regs] {
    foreach zt_z80_other [list $zt_z80_ce_regs $zt_z80_bank_regs] {
        set_multicycle_path -setup 2 -from $zt_z80_group -to $zt_z80_other
        set_multicycle_path -hold 1 -from $zt_z80_group -to $zt_z80_other
    }
}

# Active 96 MHz: DDIO inverts clk_sys, forwarding 180 degrees (donor scheme).
# Capture is on the core rising edge at STATE_READY.
# The OPL operator history shifts and sine lookup share cenop. The production
# 105/2816 sound enable and divide-by-four operator enable have measured
# minima of 26/107 core clocks, including pauses and reset clocks. Keep this
# exception at only two cycles, and only between the identified history
# shifts and the sine ROM's enabled address registers (not MMIO flags).
set zt_opl_history_regs [get_registers -nowarn {
    *|jtopl_op:u_op|jtopl_sh:u_csr0|bits*
    *|jtopl_op:u_op|jtopl_sh:u_csr1|bits*
    *|jtopl_op:u_op|jtopl_sh:u_csr2|bits*
}]
set zt_opl_sine_addr_regs [get_registers -nowarn {*|jtopl_op:u_op|jtopl_logsin:u_logsin|*porta_address_reg*}]
if {[get_collection_size $zt_opl_history_regs] < 12 || [get_collection_size $zt_opl_sine_addr_regs] < 4} {
    error "ZeroTeam OPL enabled history/sine address scope is incomplete."
}
post_message "ZeroTeam OPL history/sine scopes: [get_collection_size $zt_opl_history_regs]/[get_collection_size $zt_opl_sine_addr_regs] registers"
# history -> sine address is covered by the combined pair below (same 2/1);
# a separate overlapping pair made Quartus report both as partial multicycles.

# The operator control delay (u_delay: group/op/con/feedback/wave-select) also
# shifts only on cenop, so its path through the history mux, feedback add and
# phase add ends in cenop-enabled registers too: the sine address registers and
# the sign/nullify flags. Same 26/107-clock cenop minimum, same two-cycle limit
# (measured data delay 10.7 ns, 2 cycles = 20.8 ns).
set zt_opl_ctrl_regs [get_registers -nowarn {*|jtopl_op:u_op|jtopl_sh:u_delay|bits*}]
set zt_opl_flag_regs [get_registers -nowarn {*|jtopl_op:u_op|nullify_II *|jtopl_op:u_op|signbit_II}]
if {[get_collection_size $zt_opl_ctrl_regs] < 9 || [get_collection_size $zt_opl_flag_regs] < 2} {
    error "ZeroTeam OPL control delay/flag scopes are incomplete."
}
post_message "ZeroTeam OPL control/flag scopes: [get_collection_size $zt_opl_ctrl_regs]/[get_collection_size $zt_opl_flag_regs] registers"
# Build each union once: inline add_to_collection per command makes Quartus
# treat the setup and hold exceptions as unrelated (partial multicycle).
set zt_opl_cenop_from [add_to_collection $zt_opl_history_regs $zt_opl_ctrl_regs]
set zt_opl_cenop_to [add_to_collection $zt_opl_sine_addr_regs $zt_opl_flag_regs]
set_multicycle_path -setup 2 -from $zt_opl_cenop_from -to $zt_opl_cenop_to
set_multicycle_path -hold 1 -from $zt_opl_cenop_from -to $zt_opl_cenop_to

# SDRAM_CLK is clk_sys inverted through altddio_out (donor Raiden II scheme,
# hardware-proven on MiSTer at 96 MHz): 180 degrees from the core clock.
set zt_sdram_clock_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $zt_sdram_clock_source] != 1} {
    error "ZeroTeam SDRAM clock source is missing or ambiguous."
}
create_generated_clock -name ZT_SDRAM_CLK -source $zt_sdram_clock_source -divide_by 1 -phase 180 [get_ports SDRAM_CLK]
set zt_sdram_dq_ports [get_ports {SDRAM_DQ[*]}]
set zt_sdram_output_ports [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
if {[get_collection_size $zt_sdram_dq_ports] != 16} { error "ZeroTeam SDRAM DQ scope is incomplete." }
# ISSI IS42S16320B -6/-7 CL3 tAC <=5.4 ns, tOH/tHZ >=2.7 ns, tSU 1.5 ns,
# tH 0.8 ns; conservative allowances for board clock/data skew.
set_input_delay -clock ZT_SDRAM_CLK -max 6.0 $zt_sdram_dq_ports
set_input_delay -clock ZT_SDRAM_CLK -min 2.5 $zt_sdram_dq_ports
set_output_delay -clock ZT_SDRAM_CLK -max 2.0 $zt_sdram_output_ports
set_output_delay -clock ZT_SDRAM_CLK -min -1.3 $zt_sdram_output_ports
set zt_sdram_capture_regs [get_registers -nowarn {*|sdram:memory|dout[*]}]
if {[get_collection_size $zt_sdram_capture_regs] < 16} { error "ZeroTeam SDRAM rising-edge capture scope is incomplete." }
# CL3, burst length one: the first beat launches at READ+2 SDRAM edges.
# READY consumes the capture after the following edge, which disables
# that beat only after tOH/tHZ. Setup therefore spans 1.375 periods from
# the beat-launch edge; hold stays on the following disable edge, 0.375
# periods before capture. The pin model's max tAC and min tOH remain active.
# This selects that first-beat edge, not another cycle of RAM access time.
set_multicycle_path -setup -end 2 -from $zt_sdram_dq_ports -to $zt_sdram_capture_regs
# Zero hold shift intentionally retains setup's stricter following-edge
# hold check. Subtracting a hold cycle would incorrectly relax tOH/tHZ.
set_multicycle_path -hold -end 0 -from $zt_sdram_dq_ports -to $zt_sdram_capture_regs
post_message "ZeroTeam SDRAM rising-edge input capture: [get_collection_size $zt_sdram_capture_regs] registers"

# External pin contracts: bounded routes plus source-cadence proofs.
# HDMI DDR clock forwarding is inverted (datain_h=0, datain_l=1).
# Separate direct-video and scaler clocks describe both mux modes.
set zt_hdmi_pin [get_ports HDMI_TX_CLK]
set zt_hdmi_scaler_source [get_pins {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if {[get_collection_size $zt_hdmi_scaler_source] != 1} {error "Missing HDMI scaler clock source"}
create_generated_clock -name ZT_HDMI_SCALE_CLK -source $zt_hdmi_scaler_source -divide_by 1 -phase 180 $zt_hdmi_pin
set zt_hdmi_direct_source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $zt_hdmi_direct_source] != 1} {error "Missing HDMI direct-video clock source"}
create_generated_clock -name ZT_HDMI_DIRECT_CLK -source $zt_hdmi_direct_source -divide_by 1 -phase 180 -add $zt_hdmi_pin
set zt_hdmi_data [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
# ADV7513 Rev B data sheet: setup 1.8 ns, hold 1.3 ns. Add 0.5 ns skew.
# https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf
set_output_delay -clock ZT_HDMI_SCALE_CLK -max 2.3 $zt_hdmi_data
set_output_delay -clock ZT_HDMI_SCALE_CLK -min -1.8 $zt_hdmi_data
set_output_delay -clock ZT_HDMI_DIRECT_CLK -max 2.3 -add_delay $zt_hdmi_data
set_output_delay -clock ZT_HDMI_DIRECT_CLK -min -1.8 -add_delay $zt_hdmi_data

# These pins terminate in HPS hard peripherals / software-polled GPIO.
# The external HDMI I2C engine is not a fabric synchronous interface.
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT SDCD_SPDIF}]
set_false_path -to [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA LED[*]}]
# This target drives SD_SCK/MOSI/CS high impedance (platform.svh:6).
# SDIO outputs remaining in the fitted netlist carry analog VGA DAC bits.
set_false_path -to [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS}]

# IO-expander SDA is sampled while the externally returned ACK/data is
# stable for the I2C setup interval; limit pin-to-register routing to 20 ns.
# Pair min/max datapath bounds rather than inventing a phase to the 50 MHz clock.
set_max_delay 20.0 -from [get_ports IO_SDA]
set_min_delay 0.0 -from [get_ports IO_SDA]
# SDA is asynchronous to the fabric clock; only its external protocol
# settling interval is meaningful. Internal sampler-to-consumer hold stays timed.
set_false_path -hold -from [get_ports IO_SDA]
set_max_delay 20.0 -to [get_ports {IO_SDA IO_SCL}]
set_min_delay 0.0 -to [get_ports {IO_SDA IO_SCL}]

# The I2S generator changes data/LRCLK at the falling bit-clock phase,
# one audio clock before the forwarded SCLK changes. At 96 kHz the bit
# clock toggles every four 24.576 MHz audio cycles (48 kHz is slower).
# Bound all three pin routes to 20 ns, less than one 40.69 ns audio cycle.
# This leaves >100 ns setup/hold against the receiver's 2 ns requirement.
set zt_audio_pin_data [get_ports {HDMI_I2S HDMI_LRCLK HDMI_SCLK USER_IO[2] USER_IO[4] USER_IO[5] SDCD_SPDIF}]
set_max_delay 20.0 -to $zt_audio_pin_data
set_min_delay 0.0 -to $zt_audio_pin_data
set zt_audio_source [get_pins {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $zt_audio_source] != 1} {error "Missing audio clock source"}
create_generated_clock -name ZT_AUDIO_MCLK -source $zt_audio_source -divide_by 1 [get_ports HDMI_MCLK]
# Define the bound at the originating register, covering every forwarded
# copy. The audio source rate conservatively bounds even reset/rate-change
# pulses; stable-operation bit cadence is checked by the production test.
set zt_i2s_sclk_reg [get_registers -nowarn {*|i2s:i2s|sclk}]
if {[get_collection_size $zt_i2s_sclk_reg] != 1} {error "Missing I2S bit-clock register"}
create_generated_clock -name ZT_I2S_SCLK_BOUND -source $zt_audio_source -divide_by 1 $zt_i2s_sclk_reg
# Clock forwarding itself has no data receiver setup/hold check.
set_false_path -to [get_ports {HDMI_TX_CLK HDMI_MCLK}]

# Include the new forwarded clocks in the framework's unrelated-clock groups.
# Keep the SDRAM input/output interface related to its fabric source clock.
set_clock_groups -asynchronous \
    -group [get_clocks {*emu|pll|pll_inst* ZT_SDRAM_CLK ZT_HDMI_DIRECT_CLK}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst* ZT_HDMI_SCALE_CLK}] \
    -group [get_clocks {pll_audio|pll_audio_inst* ZT_AUDIO_MCLK ZT_I2S_SCLK_BOUND}] \
    -group [get_clocks {*h2f_user0_clk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]
derive_clock_uncertainty

# Internal setup margin for all-corner closure at unchanged 96/148.5 MHz.
# Native derived setup uncertainties are 0.290/0.200 ns respectively.
# These stricter same-clock bounds guide placement; external pin windows
# retain their independently derived clock uncertainties and timing bounds.
set zt_core_margin_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set zt_scaler_margin_clk [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if {[get_collection_size $zt_core_margin_clk] != 1 || [get_collection_size $zt_scaler_margin_clk] != 1} {
    error "ZeroTeam internal setup-margin clock scope is incomplete."
}
set_clock_uncertainty -setup -from $zt_core_margin_clk -to $zt_core_margin_clk 0.350
set_clock_uncertainty -setup -from $zt_scaler_margin_clk -to $zt_scaler_margin_clk 0.300
