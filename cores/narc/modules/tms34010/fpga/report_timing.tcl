# Additional sign-off panels loaded by quartus_sta after the fitted timing
# netlist and project SDC are active. The default report already supplies the
# per-corner slack summaries, constraint coverage, recovery/removal, pulse
# width, and metastability panels; these detailed path panels make failures
# actionable without an interactive TimeQuest session.

set core_detail_clk [get_clocks \
    {u_clock_pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set bus_detail_clk [get_clocks \
    {u_clock_pll|u_pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set video_detail_clk [get_clocks \
    {u_video_pll|u_pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set report_dir [file normalize [file join [file dirname [info script]] \
    .. work quartus output_files]]

# Keep machine-checkable copies of the two reports whose default panels are
# otherwise awkward to validate from a shell script. An empty ignored-SDC
# report proves that every named exception/filter matched the fitted netlist;
# the full chain report distinguishes the 27 explicitly forced project
# synchronizers from incidental auto-detected shift-register structures.
report_sdc -ignored -file [file join $report_dir \
    tms34010_cyclone_v.ignored_sdc.rpt]
report_metastability -nchains 375 -file [file join $report_dir \
    tms34010_cyclone_v.synchronizers.rpt]

report_timing -setup -npaths 25 -detail full_path \
    -panel_name "Task 0160 Global Setup Paths"
report_timing -setup -to_clock $core_detail_clk -npaths 25 \
    -detail full_path -panel_name "Task 0160 Core Setup Paths"
report_timing -setup -to_clock $bus_detail_clk -npaths 25 \
    -detail full_path -panel_name "Task 0160 Bus Setup Paths"
report_timing -setup -to_clock $video_detail_clk -npaths 10 \
    -detail full_path -panel_name "Task 0160 Video Setup Paths"
report_timing -setup -to [get_ports \
    {HLDA_EMUA_N LCLK1 LCLK2 LAD[*] RAS_N LAL_N CAS_N WE_N \
     TR_QE_N DEN_N DDOUT}] -npaths 25 -detail full_path \
    -panel_name "Task 0160 Local Output Paths"
report_timing -setup -to [get_ports {*}] -npaths 25 -detail full_path \
    -panel_name "Task 0160 All Output Paths"
report_timing -hold -npaths 25 -detail full_path \
    -panel_name "Task 0160 Detailed Hold Paths"
