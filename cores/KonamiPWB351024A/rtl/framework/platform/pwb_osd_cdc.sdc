# PWB held-bundle CDC: source/protocol proof is separate from physical qualification.
# No new false paths or clock changes. Fixed net budget is independent of runtime PLL.
proc pwb_osd_regs {patterns minimum maximum} {
    set regs [get_registers -nowarn $patterns]
    set count [get_collection_size $regs]
    if {$count < $minimum || $count > $maximum} {
        error "PWB OSD endpoint cardinality $count outside $minimum..$maximum for $patterns"
    }
    return $regs
}
# Native Quartus names Verilog hierarchy with optional entity:instance prefixes
# (proven in audio_out:i2s); accept only these two names for this exact child.
proc pwb_osd_patterns {instance leaf} {
    return [list "*${instance}|cfg_cdc|${leaf}" "*${instance}|pwb_osd_config_cdc:cfg_cdc|${leaf}"]
}
global pwb_osd_bridge
foreach instance {vga_osd hdmi_osd} {
    set pwb_osd_bridge($instance,held) [pwb_osd_regs [pwb_osd_patterns $instance held_bundle*] 54 2048]
    # Quartus may choose either the child output-register name or its parent net alias.
    set pwb_osd_bridge($instance,out) [pwb_osd_regs [concat [pwb_osd_patterns $instance cfg_out*] [list "*${instance}|cfg_video*"]] 54 2048]
    foreach role {cfg_req_launch cfg_req_meta cfg_req_sync cfg_ack_launch cfg_ack_meta cfg_ack_sync} {
        set pwb_osd_bridge($instance,$role) [pwb_osd_regs [pwb_osd_patterns $instance ${role}*] 1 1]
        foreach_in_collection reg $pwb_osd_bridge($instance,$role) {
            if {![string match "*|$role" [get_node_info -name $reg]]} {error "PWB CDC control renamed/cloned: $instance/$role"}
        }
    }
    set src_patterns {}
    # Include every banked local phase replica in the fixed 3.333ns source-local proof.
    foreach leaf {pending_data* pending_valid src_phase* held_bundle* cfg_req_launch cfg_ack_meta cfg_ack_sync} {
        set src_patterns [concat $src_patterns [pwb_osd_patterns $instance $leaf]]
    }
    set dst_patterns [list "*${instance}|cfg_video*"]
    foreach leaf {cfg_out* dst_phase cfg_ack_launch cfg_req_meta cfg_req_sync} {
        set dst_patterns [concat $dst_patterns [pwb_osd_patterns $instance $leaf]]
    }
    set pwb_osd_bridge($instance,src_local) [pwb_osd_regs $src_patterns 54 4096]
    set pwb_osd_bridge($instance,dst_local) [pwb_osd_regs $dst_patterns 54 4096]
    set_net_delay -max 2.000 -from $pwb_osd_bridge($instance,held) -to $pwb_osd_bridge($instance,out)
    set_net_delay -max 2.000 -from $pwb_osd_bridge($instance,cfg_req_launch) -to $pwb_osd_bridge($instance,cfg_req_meta)
    set_net_delay -max 2.000 -from $pwb_osd_bridge($instance,cfg_ack_launch) -to $pwb_osd_bridge($instance,cfg_ack_meta)
    # Stronger local helper envelope: actual PLL waveforms remain unchanged.
    set_max_delay 3.333 -from $pwb_osd_bridge($instance,src_local) -to $pwb_osd_bridge($instance,src_local)
    set_max_delay 3.333 -from $pwb_osd_bridge($instance,dst_local) -to $pwb_osd_bridge($instance,dst_local)
    puts "PWB_OSD_CDC $instance held=[get_collection_size $pwb_osd_bridge($instance,held)] out=[get_collection_size $pwb_osd_bridge($instance,out)] net_max_ns=2.000 local_max_ns=3.333"
}
