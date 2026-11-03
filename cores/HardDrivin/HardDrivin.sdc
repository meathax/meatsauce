derive_pll_clocks

# The Compact SDRAM returns DQ relative to the forwarded 100 MHz clock. Capture
# on the late-phase PLL output and constrain the external read eye (tOH >=
# 2.5 ns, tAC <= 6 ns, plus 0.5 ns board skew). Use the full hierarchy here;
# Quartus' SDC pin matcher does not resolve the shortened timing-report name.
set compact_sdram_clock_source [get_pins \
  {emu:emu|harddrivin_milestone:u_milestone|harddrivin_pll:u_pll|altera_pll:u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set compact_sdram_clock_port [get_ports {SDRAM_CLK}]
set compact_sdram_dq_ports [get_ports {SDRAM_DQ[*]}]
if {[get_collection_size $compact_sdram_clock_source] != 1 || \
    [get_collection_size $compact_sdram_clock_port] != 1 || \
    [get_collection_size $compact_sdram_dq_ports] != 16} {
  error "Compact SDRAM DQ timing constraints must match the PLL source, SDRAM_CLK, and all 16 DQ inputs"
}
create_generated_clock -name compact_sdram_clk \
  -source $compact_sdram_clock_source -divide_by 1 \
  $compact_sdram_clock_port
set_input_delay -clock compact_sdram_clk -max 6.5 $compact_sdram_dq_ports
set_input_delay -clock compact_sdram_clk -min 2.0 $compact_sdram_dq_ports

# The official MiSTer SDRAM module uses an AS4C32M16SB-7TCN. Its SDRAM
# address/control/data inputs require 1.5 ns setup and 0.8 ns hold. Include
# the same 0.5 ns module/connector skew budget used above for read data so the
# forwarded-clock output paths are checked against the external device too.
set compact_sdram_output_ports [get_ports \
  {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH \
   SDRAM_CKE SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE}]
if {[get_collection_size $compact_sdram_output_ports] != 38} {
  error "Compact SDRAM output timing constraints must match all 38 address, command, mask, and DQ pins"
}
# Board skew adds to both requirements: setup 1.5 + 0.5 = 2.0 ns, and hold
# 0.8 + 0.5 = 1.3 ns (a hold of -0.3 would credit the skew instead of charging it).
set_output_delay -clock compact_sdram_clk -max 2.0 $compact_sdram_output_ports
set_output_delay -clock compact_sdram_clk -min -1.3 $compact_sdram_output_ports

# The DQ beat launched by SDRAM clock edge X is valid only from X + 6.5 ns to
# (X + 10 ns) + 2.0 ns at the pins; it is captured by the second sample edge
# after X. Model that one-cycle interface latency with a setup multicycle of 2
# and keep the DEFAULT hold relation: hold must be checked against the same
# capture edge (the next beat launched at X + 10 ns must not arrive before it).
# A "-hold -end 1" here would move the hold check back a full period and hide
# a real failure - it previously reported +8.5 ns where the true slack was
# -1.5 ns at the fast corner (sample edge on the next beat).
set compact_sdram_high_samples [get_registers {*|sdram_dq_ddr|*dataout_h*}]
if {[get_collection_size $compact_sdram_high_samples] != 16} {
  error "Compact SDRAM must have exactly 16 high-edge DQ capture registers"
}
set_multicycle_path -setup -end 2 \
  -from $compact_sdram_dq_ports -to $compact_sdram_high_samples

# altddio_in's low-edge output is intentionally unconnected. Quartus retains
# its physical I/O register, so exclude only those unused endpoints; the high-
# edge samples and all downstream paths remain timed.
set compact_sdram_unused_low_samples [get_registers {*|sdram_dq_ddr|*DFFLO}]
if {[get_collection_size $compact_sdram_unused_low_samples] != 16} {
  error "Compact SDRAM must have exactly 16 unused low-edge DQ capture registers"
}
set_false_path -from $compact_sdram_dq_ports -to $compact_sdram_unused_low_samples

# The MiSTer framework constraint predates this core's PLL hierarchy and its
# wildcard does not match u_milestone/u_pll. The native core clocks cross into
# the stock OSD/video framework, LED plumbing, and HPS reset controls through
# deliberate asynchronous interfaces. Keep those framework clocks out of the
# core timing reports. The core clocks are split from one another below.
# Stun Runner's 40 MHz output-raster clock (PLL output 6) only crosses through
# the retimer's gray-coded pointer synchronizers. Other cores have no such
# clock, so the group is omitted there.
set pix40_clocks [get_clocks -nowarn {*u_milestone*u_pll*u_pll*general[6]*divclk}]
set pix40_group {}
if {[get_collection_size $pix40_clocks] != 0} {
  set pix40_group [list -group $pix40_clocks]
}
set_clock_groups -asynchronous \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[0]*divclk}] \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[1]*divclk \
                      *u_milestone*u_pll*u_pll*general[2]*divclk \
                      *u_milestone*u_pll*u_pll*general[4]*divclk \
                      compact_sdram_clk}] \
  -group [get_clocks {*u_milestone*u_pll*u_pll*general[3]*divclk}] \
  {*}$pix40_group \
  -group [get_clocks {FPGA_CLK1_50}] \
  -group [get_clocks {FPGA_CLK2_50}] \
  -group [get_clocks {FPGA_CLK3_50}] \
  -group [get_clocks {*h2f_user0_clk}] \
  -group [get_clocks {*pll_audio*divclk}] \
  -group [get_clocks {*pll_hdmi*divclk}]
derive_clock_uncertainty

# Carry the reusable TMS34010 core's documented timing contract into both
# GSP/MSP instances. Opcode decode and the listed state-driven register-file
# paths are architecturally separated by explicit quiet/acknowledge states;
# these are the same narrow exceptions used by the component's standalone
# Cyclone V sign-off, not blanket paths through the core.
set tms_opcode_sources [get_registers {*|u_core|instr_word_q*}]
set tms_decode_dests [get_registers {*|u_core|decoded*}]
set tms_regfile_dests [get_registers {*|u_regfile|*}]
set_multicycle_path -setup -end 2 \
  -from $tms_opcode_sources -to $tms_decode_dests
set_multicycle_path -hold -end 1 \
  -from $tms_opcode_sources -to $tms_decode_dests
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_regfile_dests

# A decoded transaction cannot reach the memory-fabric ingress in the same
# cycle.  Non-immediate instructions cross CORE_DISPATCH and CORE_EXECUTE
# before CORE_MEMORY asserts mem_req; immediate fetches cross CORE_DISPATCH
# before their first request.  The ingress registers capture the complete
# held command, and the arbiter owner can select it only on a later edge.
# Constrain only those request-capture registers; memory responses and core
# consumers retain normal single-cycle analysis.  The raw two-word on-chip
# I/O view is captured with the same held request at mem_req, before the
# fabric can acknowledge it, and is aligned only from registered operands.
set tms_memory_request_dests [get_registers \
  {*|u_memory_fabric|cpu_request_* \
   *|u_memory_fabric|u_arbiter|state_q* \
   *|u_core|io_request_wdata_q* \
   *|u_core|io_rdata_words_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_memory_request_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_memory_request_dests

# FILL's private row base cannot sample decoded instruction fields until the
# edge after both CORE_DISPATCH and CORE_EXECUTE. `decoded` is written only
# when leaving CORE_DECODE_WAIT and remains held for the entire instruction,
# so this is an explicit two-cycle datapath in both reused instances.
set tms_fill_row_base_dests [get_registers {*|u_core|fill_row_base_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_fill_row_base_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_fill_row_base_dests

# A decoded branch/call/return cannot load the program counter until
# CORE_WRITEBACK, after complete CORE_DISPATCH and CORE_EXECUTE cycles.
# FETCH/FETCH_IMM increment the PC from fetch state and memory acknowledge,
# not from decoded instruction data.  Two cycles is therefore conservative.
set tms_pc_dests [get_registers {*|u_pc|pc_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_decode_dests -to $tms_pc_dests
set_multicycle_path -hold -end 1 \
  -from $tms_decode_dests -to $tms_pc_dests

set tms_graphics_read_only_states [get_registers \
  {*|u_core|state_q.CORE_FILL_SETUP* \
   *|u_core|state_q.CORE_PBLT_SETUP* \
   *|u_core|state_q.CORE_DRAV* \
   *|u_core|state_q.CORE_LINE_SETUP* \
   *|u_core|state_q.CORE_PIXT_SETUP_WIN*}]
set_false_path -from $tms_graphics_read_only_states -to $tms_regfile_dests

set tms_memory_states [get_registers {*|u_core|state_q.CORE_MEMORY*}]
set_multicycle_path -setup -end 2 \
  -from $tms_memory_states -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_memory_states -to $tms_regfile_dests

set tms_mm_mask_sources [get_registers {*|u_core|mm_mask_q*}]
set_multicycle_path -setup -end 2 \
  -from $tms_mm_mask_sources -to $tms_regfile_dests
set_multicycle_path -hold -end 1 \
  -from $tms_mm_mask_sources -to $tms_regfile_dests

# MMTM/MMFM use the same mask to decide whether an acknowledged word returns
# to CORE_MEMORY or advances to CORE_WRITEBACK.  Neither state changes the PC;
# the earliest PC advance is a later CORE_FETCH acknowledgement.  Preserve
# that explicit quiet cycle when Quartus folds the state/data muxes together.
set_multicycle_path -setup -end 2 \
  -from $tms_mm_mask_sources -to $tms_pc_dests
set_multicycle_path -hold -end 1 \
  -from $tms_mm_mask_sources -to $tms_pc_dests

# b123 slow/hot STA: osd_de[2] -> osd_mux failed by 0.030 ns;
# 5.686 ns of its 6.034 ns data path was routing. Tighten this existing
# single-cycle path (HDMI period 6.732 ns) so placement shortens the wire.
# This changes neither pipeline latency nor clock/hold exceptions.
# Quartus automatically includes ~DUPLICATE registers for each exact RTL
# endpoint. Constrain every such copy and fail if either endpoint is absent.
set hd_osd_de2 [get_registers {hdmi_osd|osd_de[2]}]
set hd_osd_mux [get_registers {hdmi_osd|osd_mux}]
if {[get_collection_size $hd_osd_de2] < 1 || [get_collection_size $hd_osd_mux] < 1} {
  error "HardDrivin OSD route constraint must match both RTL endpoints, including fitter duplicates"
}
set_max_delay -from $hd_osd_de2 -to $hd_osd_mux 5.000
