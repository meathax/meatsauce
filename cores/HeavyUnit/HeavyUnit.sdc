# Heavy Unit: 48 MHz game clock and the actual forwarded SDRAM clock pin.
# sys/sys_top.sdc owns platform roots/clocks/standard exceptions; keep sys frozen.
derive_pll_clocks

set hu_master_pin [get_pins -compatibility_mode {emu|clock_source|pll_i|general[0].gpll*|divclk}]
if {[get_collection_size $hu_master_pin] != 1} {
    error "Heavy Unit requires exactly one 48 MHz game PLL output"
}
set hu_sdram_pin [get_ports {SDRAM_CLK}]
if {[get_collection_size $hu_sdram_pin] != 1} {
    error "Heavy Unit SDRAM clock pin missing"
}
# A second coherent PLL output advances forwarding from the failing 180-degree
# implementation. DDIO is non-inverting; the physical port includes its delay.
set hu_forward_pin [get_pins -compatibility_mode {emu|clock_source|pll_i|general[1].gpll*|divclk}]
if {[get_collection_size $hu_forward_pin] != 1} {
    error "Heavy Unit requires exactly one coherent SDRAM forwarding PLL output"
}
create_generated_clock -name hu_sdram_pin -source $hu_forward_pin -divide_by 1 $hu_sdram_pin

# ISSI IS42S16160G -6/-7, CL3: tAC=5.4, tOH=2.7, setup=1.5, hold=0.8 ns.
# Qualification envelope: clock and each data/control board path 0..0.5 ns.
# Read round trip: max=0.5+5.4+0.5=6.4; min=0+2.7+0=2.7.
# Write relative skew: max=1.5+0.5-0=2.0; min=-0.8+0-0.5=-1.3.
# This envelope is explicit; the user's actual SDRAM module is not identified.
set hu_dq [get_ports {SDRAM_DQ[*]}]
set hu_outputs [get_ports {SDRAM_DQ[*] SDRAM_A[*] SDRAM_BA[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_CKE}]
if {[get_collection_size $hu_dq] != 16 || [get_collection_size $hu_outputs] != 38} {
    error "Heavy Unit SDRAM timing port closure is incomplete"
}
set_input_delay -clock hu_sdram_pin -max 6.4 $hu_dq
set_input_delay -clock hu_sdram_pin -min 2.7 $hu_dq
set_output_delay -clock hu_sdram_pin -max 2.0 $hu_outputs
set_output_delay -clock hu_sdram_pin -min -1.3 $hu_outputs

# The custom master PLL name is outside the template's generic game-PLL
# pattern. Give master + forwarded pin the same platform clock-group policy.
# Both remain in ONE synchronous group, preserving all SDRAM read/write checks.
set hu_game_clocks [get_clocks {emu|clock_source|pll_i|*|divclk hu_sdram_pin}]
if {[get_collection_size $hu_game_clocks] != 3} {
    error "Heavy Unit master/forwarded clock relationship missing"
}
set_clock_groups -exclusive \
    -group $hu_game_clocks \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {spi_sck}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]
# Every state register in u_regs has the same reset / else-if(cen) guard.
# Constrain only those explicit state-to-state paths. Other destinations
# retain the master-clock requirement unless separately proven below.
# Source proof: docs/evidence/mermaid-register-ram-enable-contract.json.
set hu_mcu_state [get_registers {emu|game|mermaid|core|u_regs|*}]
if {[get_collection_size $hu_mcu_state] < 100} {
    error "Heavy Unit MCU state register closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_state 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_state 7
# All listed peripheral state also captures only on the same osc_cen. The
# explicit leaf prefixes exclude the serial instance's fast synchronizers.
# Reset assigns constants; external-input/enable/control paths remain at
# one master cycle. Pause only suppresses oscillator enables.
# Source proof: docs/evidence/mermaid-periph-ce-contract.json.
set hu_mcu_periph_patterns {}
foreach hu_leaf {p0 p1 p2 p3 pcon tcon tmod tl0 tl1 th0 th1 scon sbuf_rx ie ip osc service irq_delay service_low irq_vec_hold irq_vec_l irq_sel_l irq_high_l int0_l int1_l p3_4_l p3_5_l t1_ovf} {
    lappend hu_mcu_periph_patterns "emu|game|mermaid|core|u_periph|${hu_leaf}*"
}
set hu_mcu_periph [get_registers $hu_mcu_periph_patterns]
set hu_mcu_pcon [get_registers {emu|game|mermaid|core|u_periph|pcon*}]
# PCON reset/write retains only source bits 2,3,7. Other bits are constant
# zero. Verify all three logical families, accepting fitted physical replicas.
# Source: jt8051_periph.v:226; native post-map count125/periph and3/PCON.
set hu_mcu_pcon_bits {}
foreach_in_collection hu_mcu_pcon_node $hu_mcu_pcon {
    set hu_mcu_pcon_name [get_node_info -name $hu_mcu_pcon_node]
    if {![regexp {\|pcon\[(2|3|7)\](~.*)?$} $hu_mcu_pcon_name -> hu_mcu_pcon_bit]} {
        error "Heavy Unit unexpected PCON mapped register: $hu_mcu_pcon_name"
    }
    if {[lsearch -exact $hu_mcu_pcon_bits $hu_mcu_pcon_bit] < 0} {
        lappend hu_mcu_pcon_bits $hu_mcu_pcon_bit
    }
}
if {[get_collection_size $hu_mcu_periph] < 100 || [llength $hu_mcu_pcon_bits] != 3} {
    error "Heavy Unit peripheral endpoint closure incomplete: periph=[get_collection_size $hu_mcu_periph], PCON logical bits=$hu_mcu_pcon_bits"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_periph 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_periph 7
# Serial payload capture is also explicitly inside else-if(cen); baud logic
# only reads this byte. Do not include receive/control/synchronizer registers.
# Source proof: docs/evidence/mermaid-serial-tx-ce-contract.json.
set hu_mcu_tx_data [get_registers {emu|game|mermaid|core|u_periph|u_serial|tx_data*}]
if {[get_collection_size $hu_mcu_tx_data] < 8} {
    error "Heavy Unit serial payload enable endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_tx_data 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_tx_data 7
# TX control state is in that same outer else-if(cen), including baud updates.
# Reset assigns constants. Exclude RX/synchronizer/baud-divider state and keep
# tx_data in its existing separate collection so exceptions do not overlap.
# Source proof: docs/evidence/mermaid-serial-tx-controls-ce-contract.json.
set hu_mcu_tx_control_patterns {}
foreach hu_leaf {tx_busy tx_bit tx_sub rxd_o txd ti_set} {
    lappend hu_mcu_tx_control_patterns "emu|game|mermaid|core|u_periph|u_serial|${hu_leaf}*"
}
set hu_mcu_tx_control [get_registers $hu_mcu_tx_control_patterns]
set hu_mcu_tx_bit [get_registers {emu|game|mermaid|core|u_periph|u_serial|tx_bit*}]
if {[get_collection_size $hu_mcu_tx_control] < 4 || [get_collection_size $hu_mcu_tx_bit] < 4} {
    error "Heavy Unit serial TX control enable endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_tx_control 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_tx_control 7
# Board-side port shadows consume board_sfr_write=cen&&sfr_we&&!rst.
# These payload registers therefore capture only at the same oscillator edge.
# ROM address/sampling and combinational/pulse outputs are explicitly excluded.
# Source proof: docs/evidence/mermaid-wrapper-payload-ce-contract.json.
set hu_mcu_board_payload [get_registers {emu|game|mermaid|board_p1* emu|game|mermaid|old_p0* emu|game|mermaid|p1_pins* emu|game|mermaid|coin_outputs*}]
set hu_mcu_board_p1 [get_registers {emu|game|mermaid|board_p1*}]
if {[get_collection_size $hu_mcu_board_payload] < 8 || [get_collection_size $hu_mcu_board_p1] < 8} {
    error "Heavy Unit board payload enable endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_board_payload 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_board_payload 7
# MCU-sensitized changes to these two bus status bits are guarded by
# board_sfr_write=osc_cen&&sfr_we&&!rst. CPU changes on other master edges
# assign constants independently of u_regs and retain their one-cycle paths.
# Preserve CPU-set/MCU-clear and MCU-set/CPU-clear precedence in the bus.
# No response payload, CPU control or other bus endpoint is included.
# Source proof: docs/evidence/mermaid-pending-ce-contract.json.
set hu_mcu_pending [get_registers {emu|game|machine|board|bus|mermaid_command_pending* emu|game|machine|board|bus|mermaid_response_pending*}]
if {[get_collection_size $hu_mcu_pending] < 2} {
    error "Heavy Unit MCU pending status endpoint closure is incomplete: [get_collection_size $hu_mcu_pending] mapped registers"
}
# Quartus can duplicate either logical status bit. The anchored source-register
# families above include those replicas and exclude all other bus registers.
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_pending 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_pending 7
# The response byte also captures only on the same qualified MCU write.
# CPU reads clear the separate pending flag and never change this payload.
# Constrain only u_regs-sensitive paths; board_p1 launch paths stay at one
# master cycle. Exact mapped response-byte families exclude pending/CPU data.
# Source proof: docs/evidence/mermaid-response-payload-ce-contract.json.
set hu_mcu_response_payload [get_registers {emu|game|machine|board|bus|mermaid_response[*]*}]
if {[get_collection_size $hu_mcu_response_payload] < 8} {
    error "Heavy Unit MCU response payload endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_response_payload 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_response_payload 7
# The specialized MCU RAM captures normal write payload/address on osc_cen,
# then commits from those explicit registers on the next master edge.
# Keep the payload-to-RAM commit path at one master cycle. Reset payload is zero.
# Source/behavior proof: docs/evidence/mermaid-ram-pipeline.json.
set hu_mcu_write [get_registers {emu|game|mermaid|ram|write_data* emu|game|mermaid|ram|write_addr*}]
if {[get_collection_size $hu_mcu_write] < 15} {
    error "Heavy Unit MCU write pipeline endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_write 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_write 7
# The commit pulse is set only by !rst&&!reset_l&&cen&&we. Its other captures
# clear a constant zero, independently of u_regs. Do not relax the following
# pulse-to-memory commit edge, reset controls, or oscillator-enable source.
# Source proof: docs/evidence/mermaid-ram-write-pending-ce-contract.json.
set hu_mcu_write_pending [get_registers {emu|game|mermaid|ram|write_pending*}]
if {[get_collection_size $hu_mcu_write_pending] < 1} {
    error "Heavy Unit MCU RAM commit pulse endpoint closure is incomplete"
}
set_multicycle_path -setup -end -from $hu_mcu_state -to $hu_mcu_write_pending 8
set_multicycle_path -hold -end -from $hu_mcu_state -to $hu_mcu_write_pending 7
derive_clock_uncertainty
