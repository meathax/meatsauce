# Fitter-only physical delay guidance, selected explicitly in GalacticStorm.qsf.
# Original same64MHz rising-edge vf_wd->voice-RAM hold needs delay insertion.
# The first two-bit trial repaired those bits but exposed other bank bits.
# Cover the entire bank. This changes no functional latency, clock or setup
# requirement. Native TimeQuest signoff must independently reload the original
# GalacticStorm.sdc, contain none of these min-delay exceptions, and pass all
# eight supported operating conditions on the exact resulting fitted netlist.
if {![info exists ::quartus(nameofexecutable)]} {
    error "Fitter-only hold guidance requires native executable identity"
}
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
set gs_vf_hold_launch [get_registers -nowarn {*rf_es5505:sampler|vf_wd*}]
set gs_vf_hold_capture [get_registers -nowarn {*rf_es5505:sampler|altsyncram:vf_rtl_0|*porta_datain_reg*}]
if {[get_collection_size $gs_vf_hold_launch]<250 || [get_collection_size $gs_vf_hold_capture]!=294} {
    error "ES5505 fitter-only voice-write guardband must cover the whole bank"
}
puts "ES5505 FIT-ONLY guardband launch count: [get_collection_size $gs_vf_hold_launch]"
puts "ES5505 FIT-ONLY guardband capture count: [get_collection_size $gs_vf_hold_capture]"
set_min_delay 0.500 -from $gs_vf_hold_launch -to $gs_vf_hold_capture
} else {
    puts "ES5505 SIGNOFF: fitter-only hold guidance inactive in $::quartus(nameofexecutable)"
}

# Same64MHz rising-edge direct SCP control capture. The frozen bf03 fit has
# -0.105ns hold at saved_controls[123] -> layer3 cy[11] (zero logic levels).
# Add physical routing reserve only; independent STA retains original contract.
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
    set gs_scp_prefix {emu:emu|gs_game:game|gs_video_gpu:video|gs_gpu_rotate:gpu|gs_source_frame:source|gs_scp_video:scp|gs_scp_frame:renderer}
    set gs_scp_launch_count 0
    set gs_scp_capture_count 0
    foreach_in_collection gs_reg [get_registers -nowarn {*gs_scp_frame:renderer|saved_controls*}] {
        if {[get_register_info -name $gs_reg] eq "${gs_scp_prefix}|saved_controls\[123\]"} {
            set gs_scp_launch $gs_reg
            incr gs_scp_launch_count
        }
    }
    foreach_in_collection gs_reg [get_registers -nowarn {*gs_scp_frame:renderer|gs_scp_line:*|cy*}] {
        if {[get_register_info -name $gs_reg] eq "${gs_scp_prefix}|gs_scp_line:layers\[3\].coordinate|cy\[11\]"} {
            set gs_scp_capture $gs_reg
            incr gs_scp_capture_count
        }
    }
    if {$gs_scp_launch_count!=1 || $gs_scp_capture_count!=1} {
        error "SCP fitter-only guardband requires exact one launch and one capture: $gs_scp_launch_count/$gs_scp_capture_count"
    }
    puts "SCP FIT-ONLY exact launch: [get_register_info -name $gs_scp_launch]"
    puts "SCP FIT-ONLY exact capture: [get_register_info -name $gs_scp_capture]"
    set_min_delay 1.300 -from $gs_scp_launch -to $gs_scp_capture
}

# Physical-only scaler setup objective for the measured 8a8a2ec r1 path.
# Original signoff remains same HDMI rising edges at 6.732 ns: r1 data
# 6.147/6.142 ns plus adverse clock skew failed by 0.110/0.103 ns.
# This tighter objective is active ONLY in quartus_fit; it is not a waiver.
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
    set gs_scaler_launch_count 0
    set gs_scaler_capture_count 0
    foreach_in_collection gs_reg [get_registers -nowarn {*ascal*o_vacpt*}] {
        if {[get_register_info -name $gs_reg] eq {ascal:ascal|o_vacpt[4]}} {
            set gs_scaler_launch $gs_reg
            incr gs_scaler_launch_count
        }
    }
    set gs_scaler_capture [get_registers -nowarn {*ascal*o_vpixq_pre*}]
    set gs_scaler_captures {}
    foreach_in_collection gs_reg $gs_scaler_capture {
        set gs_name [get_register_info -name $gs_reg]
        if {$gs_name eq {ascal:ascal|o_vpixq_pre[3].r[4]} || $gs_name eq {ascal:ascal|o_vpixq_pre[3].g[6]}} {
            lappend gs_scaler_captures $gs_reg
            incr gs_scaler_capture_count
            puts "SCALER FIT-ONLY capture: $gs_name"
        }
    }
    if {$gs_scaler_launch_count!=1 || $gs_scaler_capture_count!=2} {
        error "Scaler fitter-only objective requires exact1launch/2captures: $gs_scaler_launch_count/$gs_scaler_capture_count"
    }
    puts "SCALER FIT-ONLY launch: [get_register_info -name $gs_scaler_launch]"
    foreach gs_capture $gs_scaler_captures {
        set_max_delay 5.500 -from $gs_scaler_launch -to $gs_capture
    }
}

# Physical-only scaler vertical-counter setup objective for the measured 5788e1d
# r1 failure: same pll_hdmi rising edges (6.732 ns), ascal o_vcpt_pre3[9] ->
# o_vcpt_pre3[0]/[4] data 6.453/6.452 ns plus -0.12 ns skew gave -0.043/-0.036 ns
# at Slow 1100mV -40C. Active ONLY in quartus_fit; the original GalacticStorm.sdc
# contract is re-run independently with none of these exceptions. Not a waiver.
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
    set gs_vcpt_regs {}
    set gs_vcpt_idx {}
    foreach_in_collection gs_reg [get_registers -nowarn {*ascal*o_vcpt_pre3*}] {
        set gs_name [get_register_info -name $gs_reg]
        if {[regexp {^ascal:ascal\|o_vcpt_pre3\[([0-9]+)\]$} $gs_name -> gs_i]} {
            lappend gs_vcpt_regs $gs_reg
            lappend gs_vcpt_idx $gs_i
        }
    }
    foreach gs_need {0 4 9} {
        if {[lsearch -exact $gs_vcpt_idx $gs_need] < 0} {
            error "Scaler vcpt fitter-only objective is missing o_vcpt_pre3\[$gs_need\]"
        }
    }
    if {[llength $gs_vcpt_regs] < 10 || [llength $gs_vcpt_regs] > 12} {
        error "Scaler vcpt fitter-only objective expects 10..12 exact bits: [llength $gs_vcpt_regs]"
    }
    puts "SCALER VCPT FIT-ONLY bits: [llength $gs_vcpt_regs] indices: [lsort -integer $gs_vcpt_idx]"
    foreach gs_launch $gs_vcpt_regs {
        foreach gs_capture $gs_vcpt_regs {
            set_max_delay 5.500 -from $gs_launch -to $gs_capture
        }
    }
}

# Attempt-2 physical-only objective (6cafb24 r2 fit): with o_vcpt_pre3 closed, the
# same pll_hdmi 6.732 ns setup pressure moved to ascal horizontal scaler endpoints
# (corner2 -0.400 o_hacc[7]->o_dir[0][10], -0.384 ->o_div[0][18], -0.366
# o_h_poly_t.r0[16]->o_h_poly_pix.r[7]). Same rule: quartus_fit only, original SDC
# contract is re-run independently without these exceptions. Not a waiver.
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
    array set gs_hz {hacc {} dir {} div {} poly_t {} poly_pix {}}
    foreach_in_collection gs_reg [get_registers -nowarn {*ascal*}] {
        set gs_name [get_register_info -name $gs_reg]
        if {![string match {ascal:ascal|o_h*} $gs_name] && ![string match {ascal:ascal|o_d*} $gs_name]} {continue}
        if {[regexp {^ascal:ascal\|o_hacc\[[0-9]+\]$} $gs_name]} {
            lappend gs_hz(hacc) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_dir\[[0-9]+\]\[[0-9]+\]$} $gs_name]} {
            lappend gs_hz(dir) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_div\[[0-9]+\]\[[0-9]+\]$} $gs_name]} {
            lappend gs_hz(div) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_h_poly_t\.[rgb][0-9]\[[0-9]+\]$} $gs_name]} {
            lappend gs_hz(poly_t) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_h_poly_pix\.[rgb]\[[0-9]+\]$} $gs_name]} {
            lappend gs_hz(poly_pix) $gs_reg
        }
    }
    foreach gs_k {hacc dir div poly_t poly_pix} {
        if {[llength $gs_hz($gs_k)] < 1} {error "Scaler horizontal fitter-only objective: no exact $gs_k registers"}
        puts "SCALER HZ FIT-ONLY $gs_k count: [llength $gs_hz($gs_k)]"
    }
    foreach gs_l $gs_hz(hacc) {
        foreach gs_c [concat $gs_hz(dir) $gs_hz(div)] {set_max_delay 5.500 -from $gs_l -to $gs_c}
    }
    foreach gs_l $gs_hz(poly_t) {
        foreach gs_c $gs_hz(poly_pix) {set_max_delay 5.500 -from $gs_l -to $gs_c}
    }
}

# Attempt-3 physical-only objective (73ea6bf r3 fit): horizontal endpoints closed,
# remaining pll_hdmi 6.732 ns setup pressure moved to ascal o_hcpt[3] -> o_radl2[4]
# (corner2 -0.088, skew -0.491, data 6.129) with o_hcpt->o_radl2[5] (+0.073) and the
# same-class vertical poly o_v_poly_t.g1[21] -> o_v_poly_pix.g[*] (+0.014..+0.099)
# next in line. Same rule: quartus_fit only; the original GalacticStorm.sdc contract
# is re-run independently without these exceptions. Not a waiver.
if {$::quartus(nameofexecutable) eq "quartus_fit"} {
    array set gs_a3 {hcpt {} radl {} vpoly_t {} vpoly_pix {}}
    foreach_in_collection gs_reg [get_registers -nowarn {*ascal*}] {
        set gs_name [get_register_info -name $gs_reg]
        if {[regexp {^ascal:ascal\|o_hcpt\[[0-9]+\]$} $gs_name]} {
            lappend gs_a3(hcpt) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_radl[0-3]\[[0-9]+\]$} $gs_name]} {
            lappend gs_a3(radl) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_v_poly_t\.[rgb][0-9]\[[0-9]+\]$} $gs_name]} {
            lappend gs_a3(vpoly_t) $gs_reg
        } elseif {[regexp {^ascal:ascal\|o_v_poly_pix\.[rgb]\[[0-9]+\]$} $gs_name]} {
            lappend gs_a3(vpoly_pix) $gs_reg
        }
    }
    foreach gs_k {hcpt radl vpoly_t vpoly_pix} {
        if {[llength $gs_a3($gs_k)] < 1} {error "Scaler attempt-3 fitter-only objective: no exact $gs_k registers"}
        puts "SCALER A3 FIT-ONLY $gs_k count: [llength $gs_a3($gs_k)]"
    }
    foreach gs_l $gs_a3(hcpt) {
        foreach gs_c $gs_a3(radl) {set_max_delay 5.500 -from $gs_l -to $gs_c}
    }
    foreach gs_l $gs_a3(vpoly_t) {
        foreach gs_c $gs_a3(vpoly_pix) {set_max_delay 5.500 -from $gs_l -to $gs_c}
    }
}
