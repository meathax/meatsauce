# Integrated divider-source constraints; full physical timing remains pending.
# REVIEW CANDIDATE. Source LAST, after every forwarded/generated clock.
# Extends only sys/sys_top.sdc's nine existing independent families, with
# Penguin.sdc's corrected core PLL identity. Never source as one group.
proc penguin_family_clocks {patterns expected label} {
    set clocks [get_clocks $patterns]
    if {[get_collection_size $clocks] != $expected} { error "Penguin clock family $label count mismatch" }
    foreach pattern $patterns {
        if {[get_collection_size [get_clocks $pattern]] != 1} { error "Penguin clock family $label missing/ambiguous: $pattern" }
    }
    return $clocks
}
set penguin_family_core [penguin_family_clocks {
    emu|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
    emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk
    penguin_sdram penguin_hdmi_direct
} 4 core]
set penguin_family_hdmi [penguin_family_clocks {
    pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk
    penguin_hdmi_scaled
} 2 scaled_hdmi]
set penguin_family_audio [penguin_family_clocks {
    pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
    penguin_i2s48 penguin_i2s96 penguin_bclk48 penguin_bclk96 penguin_user_bclk48 penguin_user_bclk96 penguin_audio_mclk
} 8 audio]
set penguin_family_spi [penguin_family_clocks {spi_sck} 1 hps_spi]
set penguin_family_hi2c [penguin_family_clocks {hdmi_sck} 1 hps_i2c]
set penguin_family_hps [penguin_family_clocks {*|h2f_user0_clk} 1 hps_user]
set penguin_family_fpga1 [penguin_family_clocks {FPGA_CLK1_50} 1 fpga1]
set penguin_family_fpga2 [penguin_family_clocks {FPGA_CLK2_50 penguin_mcp_divider100k penguin_mcp_scl} 3 fpga2_mcp]
set penguin_family_fpga3 [penguin_family_clocks {FPGA_CLK3_50} 1 fpga3]
# Nine groups preserve precisely the parent's existing 36 pairwise cuts.
# Related clocks within a family remain timed, except the already-owned
# direct/scaled and 48/96-mode exclusive relationships in platform-io.sdc.
set_clock_groups -asynchronous \
    -group $penguin_family_core -group $penguin_family_hdmi \
    -group $penguin_family_audio -group $penguin_family_spi \
    -group $penguin_family_hi2c -group $penguin_family_hps \
    -group $penguin_family_fpga1 -group $penguin_family_fpga2 \
    -group $penguin_family_fpga3

# Source-bound minimum enable spacing, verified by exhaustive negative-tested
# proofs in sim/nonquartus/{crt_multicycle,map_multicycle}. Master stays100MHz.
# No exception on other arithmetic inputs, feedback, control or other sinks.
namespace eval ::penguin_proven_enable_spacing {
    set crt_source [get_registers {*crt_height*|vsize_eff[*]}]
    set crt_sink [get_registers {*crt_height*|t_vsdel[*]}]
    if {[get_collection_size $crt_source] != 6 || [get_collection_size $crt_sink] != 5} {
        error "CRT enable-spacing contract needs exactly6 source and5 sink FFs"
    }
    set_multicycle_path 2 -setup -end -from $crt_source -to $crt_sink
    set_multicycle_path 1 -hold -end -from $crt_source -to $crt_sink
    set map_source [get_registers {*engine*|map_x_step*}]
    set map_sink [get_registers {*engine*|map_tile_base*}]
    if {[get_collection_size $map_source] < 1 || [get_collection_size $map_sink] < 1} {
        error "Map enable-spacing contract lost its named register families"
    }
    set_multicycle_path 2 -setup -end -from $map_source -to $map_sink
    set_multicycle_path 1 -hold -end -from $map_source -to $map_sink
}
