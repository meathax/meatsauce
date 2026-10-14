#!/usr/bin/env python3
"""Diagnose ADV7513 video pins on a saved fit, without changing production SDC.

Both clock-mux modes, nominal fitted PLL frequencies, all programmable input
clock delays, provisional board flight bounds. Does not qualify HPS dynamic PLL
configuration, CDC, audio, I2C, or production closure. Never invokes assembler.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

def _sq_refuse_quartus(recipe):
    raise RuntimeError('Standalone Quartus operations are disabled. Use canonical quartus_flow.ps1 -Action Start -RecipeId '
                       + recipe + ' after the complete recipe is registered. Assembly authority remains separate.')


ROOT=Path(__file__).resolve().parents[1]
TCL=r"""package require ::quartus::sta
project_open CrystalSystem
create_timing_netlist
read_sdc
file mkdir hdmi_video_probe
set output_clock [get_ports {HDMI_TX_CLK}]
set video [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]
if {[get_collection_size $video] != 27} {error "expected 27 video data/control pins"}
set core [get_pins -compatibility_mode {*emu|pll|pll_inst*general[0]*PLL_OUTPUT_COUNTER*divclk}]
set scaled [get_pins -compatibility_mode {*pll_hdmi*counter[0].output_counter|divclk}]
set mux [get_pins -compatibility_mode {hdmi_clk_sw|outclk}]
if {[get_collection_size $mux] != 1} {error "expected one HDMI clock mux output"}
foreach {mode source} [list native $core scaled $scaled] {
 if {[get_collection_size $source] != 1} {error "expected one $mode clock source"}
 foreach_in_collection pin $source {set master [get_node_info -name $pin]}
 if {[get_collection_size [get_clocks -nowarn $master]] != 1} {error "missing source clock $master"}
 # DDR forwarding is h=0/l=1: rising receiver edge is source falling edge.
 create_generated_clock -name cs_hdmi_mux_$mode -source $source -master_clock $master -divide_by 1 -add $mux
 set masters($mode) cs_hdmi_mux_$mode
 create_generated_clock -name cs_hdmi_$mode -source $mux -master_clock cs_hdmi_mux_$mode -invert -add $output_clock
 # Rev B tSU=1.8ns, tH=1.3ns; 0xBA delay -1.2..+1.6ns.
 # clock/data flights each 0..0.5ns => differential bound +/-0.5ns.
 set_output_delay -clock cs_hdmi_$mode -max 3.5 -add_delay $video
 set_output_delay -clock cs_hdmi_$mode -min -3.4 -add_delay $video
}
# One physical mux output: the two propagated mode clocks cannot coexist.
set_clock_groups -logically_exclusive -group {cs_hdmi_mux_native cs_hdmi_native} -group {cs_hdmi_mux_scaled cs_hdmi_scaled}
derive_clock_uncertainty
update_timing_netlist
report_clocks -file hdmi_video_probe/clocks.rpt
set corner 0
foreach_in_collection op [get_available_operating_conditions] {
 set_operating_conditions $op
 update_timing_netlist
 foreach mode {native scaled} {
  report_timing -setup -from_clock $masters($mode) -to $video -to_clock cs_hdmi_$mode -npaths 3 -detail full_path -file hdmi_video_probe/corner${corner}_${mode}_setup.rpt
  report_timing -hold -from_clock $masters($mode) -to $video -to_clock cs_hdmi_$mode -npaths 3 -detail full_path -file hdmi_video_probe/corner${corner}_${mode}_hold.rpt
 }
 incr corner
}
project_close -dont_export_assignments
"""

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('snapshot')
    ap.add_argument('--main-default',action='store_true',help='upstream Main 0xBA=0x60/no receiver delay; installed HPS configuration still unverified')
    args=ap.parse_args()
    stage=Path(args.snapshot).resolve()
    profile='hdmi_video_main_default_probe' if args.main_default else 'hdmi_video_probe'
    delay_min,delay_max=(0.0,0.0) if args.main_default else (-1.2,1.6)
    output_max=1.8-delay_min+0.5
    output_min=-(1.3+delay_max+0.5)
    tcl=TCL.replace('hdmi_video_probe',profile).replace('-max 3.5',f'-max {output_max}').replace('-min -3.4',f'-min {output_min}')
    if (ROOT/'sim/obj_dir/production').resolve() not in stage.parents:
        raise RuntimeError('requires saved production snapshot')
    if 'Successful' not in (stage/'output_files/CrystalSystem.fit.summary').read_text():
        raise RuntimeError('requires successful fit')
    protected={p:p.read_bytes() for p in (stage/'CrystalSystem.qsf',stage/'CrystalSystem.sdc')}
    script=stage/(profile+'.tcl')
    script.write_text(tcl)
    log=stage/(profile+'.log')
    started=time.monotonic()
    try:
        with log.open('w') as output:
            proc=_sq_refuse_quartus('brazz-hdmi-video-complete-diagnostic')
            print('QUARTUS_PID hdmi_video_probe '+str(proc.pid),flush=True)
            code=proc.wait()
    finally:
        for p,data in protected.items():
            if p.read_bytes()!=data:p.write_bytes(data)
    errors=[s for s in log.read_text(errors='replace').splitlines() if re.match(r'\s*(?:Error|Fatal Error)\b',s)][:12]
    paths=[]
    if not code and not errors:
        for p in sorted((stage/profile).glob('corner*.rpt')):
            body=p.read_text(errors='replace')
            match=re.search(r'Path #1: (?:Setup|Hold) slack is (-?\d+(?:\.\d+)?)',body)
            if not match:raise RuntimeError('missing required HDMI timing path '+str(p))
            paths.append({'report':str(p),'slack_ns':float(match.group(1))})
    result={'status':'PROBE_ERROR' if code or errors else 'PROBE_COMPLETE','snapshot':str(stage),'seconds':round(time.monotonic()-started,3),'returncode':code,'errors':errors,'paths':paths,
      'scope':'saved-fit diagnostic; matching source/receiver clock modes only; nominal PLL frequencies; not cross-mode CDC, dynamic-mode or production signoff',
      'profile':{'receiver':'ADV7513','setup_ns':1.8,'hold_ns':1.3,'programmable_clock_delay_ns':[delay_min,delay_max],'configuration':'upstream Main register0xBA=0x60; installed HPS not verified' if args.main_default else 'all register0xBA settings','board_flights_ns':[0,0.5],'board_bounds_measured':False,'output_max_ns':output_max,'output_min_ns':output_min,
      'sources':['https://www.analog.com/media/en/technical-documentation/data-sheets/adv7513.pdf','https://www.analog.com/media/en/technical-documentation/user-guides/adv7513_programming_guide.pdf','https://github.com/MiSTer-devel/Main_MiSTer/blob/master/video.cpp#L1498','https://www.intel.com/content/www/us/en/support/programmable/support-resources/design-examples/quartus/exm-tq-clock-mux.html']},'script_sha256':hashlib.sha256(tcl.encode()).hexdigest(),'log':str(log)}
    (ROOT/('docs/hdmi_video_pin_main_default_probe.json' if args.main_default else 'docs/hdmi_video_pin_probe.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)
    return code or int(bool(errors))
if __name__=='__main__':raise SystemExit(main())
