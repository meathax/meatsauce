# ACK-qualified64-bit graphics payload only. See isolated candidate
# ack-stability.md and four-state io-dma-master-forward/qualification.json.
# Source stays inactive >=4 periods before ACK, >=5 before actual cache copy;
# earliest next enabled payload follows copy by >=9 logical master periods.
# No raw-input, ACK/control, write-pin, CPU-CE or arbitrary IO exception.
namespace eval ::penguin_dma_ack_contract {
    set payload [get_registers {*graphics_sdram*video_dma_data[*]}]
    set master [get_clocks {emu|pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
    set io [get_clocks {emu|pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
    if {[get_collection_size $payload] != 64} {error "DMA ACK source must be EXACTLY64 FFs"}
    if {[get_collection_size $master] != 1 || [get_collection_size $io] != 1} {
        error "DMA ACK related MASTER/IO clock roles missing"
    }
    # All actual clocked MASTER sinks must pass the post-fit endpoint whitelist:
    # graphics_cache.cache_data_way0/1 and graphics_cache.renderer_dout only.
    set_multicycle_path 5 -setup -end -from $payload -to $master
    set_multicycle_path 4 -hold -end -from $payload -to $master
}
