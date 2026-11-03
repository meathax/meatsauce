# Diagnostic receiver target: ADV7513 SDR444, Main0xBA0x60, zero differential PCB skew.
# Native fitted I/O load/electrical model retained; no installed-board guarantee.
proc spinal_hdmi_receiver {} {
 set pins [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
 set port [get_ports HDMI_TX_CLK]
 set sys [get_clocks {*emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
 set hdmi [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
 foreach {label coll count} [list pins $pins 27 port $port 1 sys $sys 1 hdmi $hdmi 1] {
  if {[get_collection_size $coll]!=$count} {error "HDMI exact collection $label"}
 }
 foreach {label parent} [list native $sys scaled $hdmi] {
  set name [get_clock_info -name $parent]
  set root [get_pins -compatibility_mode $name]
  if {[get_collection_size $root]!=1} {error "HDMI root $label"}
  create_generated_clock -name spinal_hdmi_${label}_forward -source $root -master_clock $name -divide_by 1 -invert -add $port
  set_output_delay -clock spinal_hdmi_${label}_forward -max 1.8 -add_delay $pins
  set_output_delay -clock spinal_hdmi_${label}_forward -min -1.3 -add_delay $pins
 }
 derive_clock_uncertainty
}
spinal_hdmi_receiver
rename spinal_hdmi_receiver {}

# Logical modes of ONE real selected output domain. Both upstream PLL clocks
# physically exist; no upstream physical-exclusivity assertion is made here.
# Final HDMI D/DE/HS/VS FFs and H0/L1 forwarded DDIO share hdmi_tx_clk.
# Read after the exact two HDMI_TX_CLK generated-clock definitions.
proc spinal_hdmi_legal_modes {} {
 set sys [get_clocks {*emu|pll|pll_inst|altera_pll_i|*[0].*|divclk}]
 set hdmi [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
 set native_port [get_clocks spinal_hdmi_native_forward]
 set scaled_port [get_clocks spinal_hdmi_scaled_forward]
 foreach {label coll} [list sys $sys hdmi $hdmi native_port $native_port scaled_port $scaled_port] {
  if {[get_collection_size $coll]!=1} {error "HDMI mode clock inventory $label"}
 }
 set native_group [add_to_collection $sys $native_port]
 set scaled_group [add_to_collection $hdmi $scaled_port]
 if {[get_collection_size $native_group]!=2 || [get_collection_size $scaled_group]!=2} {error "HDMI mode group cardinality"}
 set_clock_groups -logically_exclusive -group $native_group -group $scaled_group
}
spinal_hdmi_legal_modes
rename spinal_hdmi_legal_modes {}
