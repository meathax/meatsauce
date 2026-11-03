# Registered core indicator -> first 50MHz sample only. Independent level
# statuses are consumed after two samples; all same-50MHz paths stay timed.
# Proof: evidence/sim/mcp-led-cdc-20261024-04/receipt.json.
proc mm_mcp_led_bus {stem} {
    set nodes [get_registers "*mcp23009|${stem}*"]
    set bits [dict create]
    foreach_in_collection n $nodes {
        set name [get_register_info -name $n]
        if {![regexp {\|(mm_led_meta|mm_led_sync)\[([0-2])\]$} $name match found bit] || $found ne $stem} {error "Foreign MCP LED boundary register: $name"}
        if {[dict exists $bits $bit]} {error "MCP LED boundary register duplicated"}
        dict set bits $bit 1
    }
    if {![dict exists $bits 0] || ![dict exists $bits 1] || [dict size $bits]<2 || [dict size $bits]>3} {error "MCP LED dynamic boundary bits missing"}
    # Bit2 is the source-proven constant LED_POWER=00; it may be pruned.
    return $nodes
}
set mm_mcp_led_first [mm_mcp_led_bus mm_led_meta]
set mm_mcp_led_second [mm_mcp_led_bus mm_led_sync]
if {[get_collection_size $mm_mcp_led_first]!=[get_collection_size $mm_mcp_led_second]} {error "MCP LED stage inventories differ"}
set mm_mcp_led_launch [mm_cdc_regs {*|mcp_led_user_launch} 1]
set mm_mcp_led_first0 [mm_cdc_regs {*mcp23009|mm_led_meta[0]} 1]
set_false_path -from $mm_mcp_led_launch -to $mm_mcp_led_first0
