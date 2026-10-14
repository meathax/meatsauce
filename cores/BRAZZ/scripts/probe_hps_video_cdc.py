"""Report actual fitted counter synchronizers, without changing constraints or invoking assembly."""
import argparse,hashlib,json,re,subprocess,time
from pathlib import Path

def _sq_refuse_quartus(recipe):
    raise RuntimeError('Standalone Quartus operations are disabled. Use canonical quartus_flow.ps1 -Action Start -RecipeId '
                       + recipe + ' after the complete recipe is registered. Assembly authority remains separate.')

ROOT=Path(__file__).resolve().parents[1]
TCL=r"""package require ::quartus::sta
project_open CrystalSystem
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir hps_video_cdc
set meta [get_registers {*|hps_io|video_calc|calc_sync_meta[*]}]
set sync [get_registers {*|hps_io|video_calc|calc_sync[*]}]
if {[get_collection_size $meta]!=4 || [get_collection_size $sync]!=4} {error "expected four real two-stage counter synchronizers"}
set corner 0
foreach_in_collection op [get_available_operating_conditions] {
 set_operating_conditions $op
 update_timing_netlist
 report_timing -setup -from $meta -to $sync -npaths 4 -detail full_path -file hps_video_cdc/corner${corner}_setup.rpt
 report_timing -hold -from $meta -to $sync -npaths 4 -detail full_path -file hps_video_cdc/corner${corner}_hold.rpt
 report_metastability -nchains 2000 -file hps_video_cdc/corner${corner}_metastability.rpt
 incr corner
}
project_close -dont_export_assignments
"""
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('snapshot');args=ap.parse_args();stage=Path(args.snapshot).resolve()
 if (ROOT/'sim/obj_dir/production').resolve() not in stage.parents:raise RuntimeError('requires saved production fit')
 if not (stage/'check_report.json').exists():raise RuntimeError('wait until the production job ends')
 if 'Successful' not in (stage/'output_files/CrystalSystem.fit.summary').read_text(errors='replace'):raise RuntimeError('requires successful fit')
 protected={p:p.read_bytes() for p in (stage/'CrystalSystem.qsf',stage/'CrystalSystem.sdc')}
 script=stage/'hps_video_cdc.tcl';script.write_text(TCL);log=stage/'hps_video_cdc.log';start=time.monotonic()
 try:
  with log.open('w') as out:r=_sq_refuse_quartus('brazz-hps-video-cdc-complete-diagnostic')
 finally:
  for p,b in protected.items():
   if p.read_bytes()!=b:p.write_bytes(b)
 errors=[s for s in log.read_text(errors='replace').splitlines() if re.match(r'\s*(?:Error|Fatal Error)',s)][:8]
 reports=[];chains=[]
 if not r.returncode and not errors:
  for p in sorted((stage/'hps_video_cdc').glob('corner*.rpt')):
   body=p.read_text(errors='replace')
   if 'metastability' in p.name:
    rows=[s for s in body.splitlines() if 'calc_sync_meta[' in s]
    chains.append({'report':str(p),'counter_chain_rows':rows,'limits':'Default tool toggle assumptions; overall design MTBF is unavailable while other timing fails.'})
   else:
    slacks=[float(s) for s in re.findall(r'Path #[0-9]+: (?:Setup|Hold) slack is (-?[0-9.]+)',body)]
    if len(slacks)!=4:raise RuntimeError('missing fitted counter chain paths '+str(p))
    reports.append({'report':str(p),'slacks_ns':slacks})
 result={'status':'PROBE_ERROR' if r.returncode or errors else 'PROBE_COMPLETE','scope':'Four actual first-to-second-stage paths and fitted metastability reports; no constraints changed, no whole-design closure claim','snapshot':str(stage),'returncode':r.returncode,'errors':errors,'seconds':round(time.monotonic()-start,3),'paths':reports,'chains':chains,'script_sha256':hashlib.sha256(TCL.encode()).hexdigest(),'log':str(log)}
 (ROOT/'docs/hps_video_cdc_probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ('status','returncode','errors','seconds','snapshot')}));return r.returncode or int(bool(errors))
if __name__=='__main__':raise SystemExit(main())
