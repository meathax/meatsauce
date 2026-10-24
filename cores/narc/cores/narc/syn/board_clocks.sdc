# Inserted immediately after derive_pll_clocks by prepare_quartus_linux.py.
# Children must exist before the framework evaluates its root clock groups.
set narc_mem_src [get_pins -compatibility_mode {*general[5]*divclk*}]
if {[get_collection_size $narc_mem_src] != 1} {error "NARC SDRAM PLL source cardinality"}
create_generated_clock -name NARC_SDRAM_PAD -source $narc_mem_src [get_ports SDRAM_CLK]

set narc_jc [get_pins -compatibility_mode {*JCLOCKS[4]|clk}]
set narc_jq [get_pins -compatibility_mode {*JCLOCKS[4]|q}]
if {[get_collection_size $narc_jc] != 1 || [get_collection_size $narc_jq] != 1} {error "NARC DB15 divider cardinality"}
create_generated_clock -name NARC_DB15 -divide_by 32 -source $narc_jc $narc_jq

set narc_hdmi_mux [get_pins -compatibility_mode {hdmi_clk_sw|outclk}]
set narc_native [get_clocks {*|pll|pll_inst|altera_pll_i|general[4]*|divclk}]
set narc_scaled [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*counter[0]*|divclk}]
if {[get_collection_size $narc_hdmi_mux] != 1 || [get_collection_size $narc_native] != 1 || [get_collection_size $narc_scaled] != 1} {error "NARC HDMI source cardinality"}
# The pad DDIO emits low on the selected clock's rising edge.
create_generated_clock -name NARC_HDMI_NATIVE -master_clock $narc_native -source $narc_hdmi_mux -invert [get_ports HDMI_TX_CLK]
create_generated_clock -name NARC_HDMI_SCALED -master_clock $narc_scaled -source $narc_hdmi_mux -invert -add [get_ports HDMI_TX_CLK]

set narc_audio_src [get_pins -compatibility_mode {pll_audio|pll_audio_inst|altera_pll_i|general[0]*|divclk}]
if {[get_collection_size $narc_audio_src] != 1} {error "NARC audio PLL source cardinality"}
create_generated_clock -name NARC_AUDIO_MCLK -source $narc_audio_src [get_ports HDMI_MCLK]
