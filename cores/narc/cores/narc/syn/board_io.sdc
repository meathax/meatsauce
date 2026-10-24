# Fixed96MHz NARC pad profile. AS4C16M16SA -6/-7 Rev3 pp19,22, CL2.
# Direct module envelope: each clock/DQ/command PCB flight 0..1.5ns.
# tAC<=6ns, tOH>=2.5ns, tIS>=1.5ns, tIH>=0.8ns.
set narc_dq [get_ports {SDRAM_DQ[*]}]
set narc_dq_capture [get_registers -nowarn {*u_io*dq_capture[*]}]
set narc_mem_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS}]
if {[get_collection_size $narc_dq] != 16 || [get_collection_size $narc_dq_capture] != 16 || [get_collection_size $narc_mem_out] != 37} {error "NARC SDRAM endpoint cardinality"}
set_input_delay -clock NARC_SDRAM_PAD -max 9.0 $narc_dq
set_input_delay -clock NARC_SDRAM_PAD -min 2.5 $narc_dq
set_output_delay -clock NARC_SDRAM_PAD -max 3.0 $narc_mem_out
set_output_delay -clock NARC_SDRAM_PAD -min -2.3 $narc_mem_out
# Full-rate consecutive beats, not a CE relaxation. For pad rising phase+1.823
# and fabric falling capture+5.208, capture the PREVIOUS pad edge's beat.
# Setup2 moves capture forward10.416ns; its default hold movement checks the
# NEXT pad edge against that same capture. Deliberately NO N-1 hold repair.
# tests/sdram_pin binds READ+(CL-1)+tAC, ordering and unsafe negative controls.
set_multicycle_path -setup 2 -from $narc_dq -to $narc_dq_capture

# ADV7513 RevB video setup1.8ns/hold1.3ns. Onboard clock/data flight0..0.5ns.
# Fixed generated 148.5MHz scaled and96MHz native HDMI modes only.
set narc_video [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $narc_video] != 27} {error "NARC HDMI port cardinality"}
foreach c {NARC_HDMI_NATIVE NARC_HDMI_SCALED} {
 set_output_delay -clock $c -max 2.3 -add_delay $narc_video
 set_output_delay -clock $c -min -1.8 -add_delay $narc_video
}

# DB15 optional shift-register return: /32 clock, <=100ns total return delay.
# Covers clock pad/PCB, 74HC165/4021 propagation and return PCB at3MHz.
set_input_delay -clock NARC_DB15 -max 100.0 [get_ports {USER_IO[5]}]
set_input_delay -clock NARC_DB15 -min 0.0 [get_ports {USER_IO[5]}]

# I2S is CE scheduled, not a generated FF clock. Its three pad FFs are
# physically bounded here; the protocol witness checks >=one whole audio
# clock between data/LRCLK changes and every active SCLK rising edge.
# 40.68ns minimum parent period -16ns differential pad budget -1ns board
# skew exceeds ADV7513's2ns setup/hold. Reset framing is not valid audio.
set narc_i2s [get_keepers -nowarn {*audio_out*|*i2s*|sdata* *audio_out*|*i2s*|lrclk* *audio_out*|*i2s*|sclk*}]
set narc_i2s_ports [get_ports {HDMI_I2S HDMI_LRCLK HDMI_SCLK}]
if {[get_collection_size $narc_i2s] < 3 || [get_collection_size $narc_i2s_ports] != 3} {error "NARC I2S endpoint cardinality"}
# Scope by the three exact pad endpoints so fitter-created FF copies cannot
# escape the budget. Native reports must confirm every source is an I2S FF.
set_max_delay 16.0 -to $narc_i2s_ports
set_min_delay 0.0 -to $narc_i2s_ports

# MCP23009 standard fast-mode timing at250kHz, CLK50MHz. Source CLK-counter
# half-period100cycles; SDA pipelined80ns after falling clock, input samples
# 20ns after rising clock. See tests/platform_i2c/README.md for edge proof,
# device bounds, startup convergence, OE transport and electrical envelope.
set narc_mcp_in [get_ports IO_SDA]
set narc_mcp_regs [get_keepers -nowarn {*mcp23009*|*i2c*|ACK* *mcp23009*|*i2c*|rdata*}]
set narc_mcp_out [get_ports {IO_SCL IO_SDA}]
# Five used GPIO bits (dout[7:3]) map to rdata[0:4], plus ACK. The
# remaining receiver bits may be pruned; retain every physical copy.
catch {array unset narc_mcp_logical}
foreach_in_collection n $narc_mcp_regs {
 set narc_mcp_name [get_register_info -name $n]
 if {[regexp {\|ACK(~.*)?$} $narc_mcp_name]} {
  set narc_mcp_logical(ACK) 1
 } elseif {[regexp {\|rdata\[([0-7])\](~.*)?$} $narc_mcp_name -> bit]} {
  set narc_mcp_logical($bit) 1
 } else {error "Unexpected MCP receiver endpoint $narc_mcp_name"}
}
foreach required {ACK 0 1 2 3 4} {
 if {![info exists narc_mcp_logical($required)]} {error "Missing MCP logical receiver $required"}
}
if {[get_collection_size $narc_mcp_in] != 1 || [get_collection_size $narc_mcp_out] != 2} {error "NARC MCP port cardinality"}
puts "NARC_MCP_RECEIVERS [get_collection_size $narc_mcp_regs] REQUIRED_ACK_PLUS_BITS_0_TO_4"
# Root-to-OE-pad bounds include clock insertion; no fake I2C event clock.
set_max_delay 20.0 -to $narc_mcp_out
set_min_delay 0.0 -to $narc_mcp_out
# Input path delay relative to capture-clock insertion is bounded both ways.
# These bounds combine with the protocol's738ns setup/1960ns hold reserves.
set_max_delay 20.0 -from $narc_mcp_in
set_min_delay -20.0 -from $narc_mcp_in
