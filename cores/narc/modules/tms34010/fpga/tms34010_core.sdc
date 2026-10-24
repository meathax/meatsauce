# TMS34010_sv: the CPU's own timing exceptions (multicycle and false paths inside tms34010_core).
#
# Read this file from any project's SDC after its clocks are created, for example
#   source [file join [file dirname [info script]] tms34010_core.sdc]           (from this folder)
#   source <path to the CPU repo>/fpga/tms34010_core.sdc                          (from a game core)
# It only names registers inside the CPU, through the CPU's own instance names (u_core, u_core|u_regfile,
# u_core|u_pc), behind a leading wildcard, so it works wherever tms34010_system sits in the hierarchy
# (e.g. ...|u_gsp|u_core|...). It creates no clocks and touches no ports.
#
# Every exception is a property of the core's state sequence, explained beside it; none depends on the
# board, the memory or the clock frequency.
#
# The two groups that name state bits (state_q.CORE_*) match only when Quartus extracts the core's state
# machine one-hot under those names. Where it does not, Quartus reports "Ignored filter ... could not be
# matched" for them and simply leaves those paths unrelaxed; every exception here only relaxes, so that is
# safe (the CPU-alone build meets timing either way).

# The opcode word changes only on an acknowledged fetch. CORE_DECODE and
# CORE_DECODE_WAIT hold it stable for two complete periods before the explicit
# packed decoded register samples it. From CORE_DISPATCH, at least EXECUTE and
# WRITEBACK separate that registered record from an architectural regfile
# update. Later result registers (multiply/divide/memory) retain ordinary
# single-cycle analysis.
set core_opcode_sources [get_registers {*|u_core|instr_word_q*}]
set core_decode_dests [get_registers {*|u_core|decoded*}]
set core_regfile_dests [get_registers {*|u_core|u_regfile|*}]
set_multicycle_path -setup -end 2 \
    -from $core_opcode_sources -to $core_decode_dests
set_multicycle_path -hold -end 1 \
    -from $core_opcode_sources -to $core_decode_dests
set_multicycle_path -setup -end 2 \
    -from $core_decode_dests -to $core_regfile_dests
set_multicycle_path -hold -end 1 \
    -from $core_decode_dests -to $core_regfile_dests

# The program counter, likewise: the decoded record is captured at the end of
# CORE_DECODE_WAIT; the PC holds in CORE_DISPATCH (no load, no advance), its
# advances in the fetch states depend only on the state and the memory
# acknowledge, and every decoded-dependent load happens in CORE_WRITEBACK, at
# least two periods after the record changes.
set core_pc_dests [get_registers {*|u_core|u_pc|*}]
set_multicycle_path -setup -end 2 \
    -from $core_decode_dests -to $core_pc_dests
set_multicycle_path -hold -end 1 \
    -from $core_decode_dests -to $core_pc_dests

# The multiply product register loads at the end of CORE_EXECUTE, which is
# never sooner than CORE_DISPATCH plus one period after the record changes
# (CORE_DECODE_WAIT always goes to CORE_DISPATCH).
set core_mpy_dests [get_registers {*|u_core|mpy_product_q*}]
set_multicycle_path -setup -end 2 \
    -from $core_decode_dests -to $core_mpy_dests
set_multicycle_path -hold -end 1 \
    -from $core_decode_dests -to $core_mpy_dests

# Graphics setup/draw states temporarily repurpose the asynchronous register
# file read selectors to collect implied B-file operands. Those state bits
# cannot qualify a register-file write: DRAV writes only the already-latched
# XY advance in CORE_WRITEBACK, while LINE writes only its dedicated line
# registers in CORE_LINE_WB_*. Cut only these impossible state-to-storage data
# paths; their real state-to-capture and state-to-write-enable paths retain
# ordinary single-cycle analysis.
set graphics_read_only_states [get_registers \
    {*|u_core|state_q.CORE_FILL_SETUP* \
     *|u_core|state_q.CORE_PBLT_SETUP* \
     *|u_core|state_q.CORE_DRAV* \
     *|u_core|state_q.CORE_LINE_SETUP* \
     *|u_core|state_q.CORE_PIXT_SETUP_WIN*}]
set_false_path -from $graphics_read_only_states -to $core_regfile_dests

# CORE_MEMORY lasts through a registered fabric transaction. Its state bit
# selects many mutually exclusive data-mux arms, but no state transition can
# itself qualify register-file sampling at the next edge: MMFM,
# auto-increment, and pointer writes all require a later memory acknowledge.
# The integrated classification stage plus request/acknowledge mailbox makes
# two core periods the conservative minimum; actual payload sources retain
# their ordinary timing.
set core_memory_state [get_registers {*|u_core|state_q.CORE_MEMORY*}]
set_multicycle_path -setup -end 2 \
    -from $core_memory_state -to $core_regfile_dests
set_multicycle_path -hold -end 1 \
    -from $core_memory_state -to $core_regfile_dests

# The multiple-register transfer mask advances only on an acknowledged word.
# Its next priority-encoded register selection cannot be consumed until a
# subsequent fabric transaction completes.
set core_mm_mask_sources [get_registers {*|u_core|mm_mask_q*}]
set_multicycle_path -setup -end 2 \
    -from $core_mm_mask_sources -to $core_regfile_dests
set_multicycle_path -hold -end 1 \
    -from $core_mm_mask_sources -to $core_regfile_dests
