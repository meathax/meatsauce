#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Qualify corrected source controls and held mode transitions once in Ubuntu."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 root=Path(__file__).resolve().parents[1]; check=root/'_checks/agent-color-control-20261010/native';check.mkdir(exist_ok=False)
 linux='/mnt/'+root.drive[0].lower()+root.as_posix()[2:];build=linux+'/_checks/agent-color-control-20261010/native/build'
 files=['rtl/n8080_color_latch.sv','rtl/n8080_color_path.sv','sim/color_path_qualification.cpp','tools/qualify_color_path.py','docs/COLOR_PATH.md','docs/COLOR_CONTROL_TRACE.md','docs/evidence/sheriff_color_control_trace.json']
 before={f:sha(root/f) for f in files};base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
 cmds=[base+['verilator','--cc','--exe','--build','--top-module','n8080_color_path','--Mdir',build,'--threads','1','-j','2','-Wno-fatal',files[0],files[1],linux+'/'+files[2]],base+[build+'/Vn8080_color_path']]
 receipts=[]
 for stage,cmd in zip(['build','native'],cmds):
  start=datetime.now(timezone.utc).isoformat();v=subprocess.run(cmd,capture_output=True)
  (check/(stage+'.stdout.log')).write_bytes(v.stdout);(check/(stage+'.stderr.log')).write_bytes(v.stderr)
  rec={'command':cmd,'start_utc':start,'finish_utc':datetime.now(timezone.utc).isoformat(),'exit_code':v.returncode,'stdout_path':str(check/(stage+'.stdout.log')),'stderr_path':str(check/(stage+'.stderr.log'))}
  (check/(stage+'-receipt.json')).write_text(json.dumps(rec,indent=2)+'\n',newline='');receipts.append(rec)
  print(stage+' exit='+str(v.returncode),flush=True)
  if v.returncode:print(v.stderr.decode(errors='replace')[-3500:]);raise SystemExit(v.returncode)
 expected='PASS corrected_captures=64 live_mode_hold_checks=256 static_MAME_matches=64 video_blank_checks=256'
 assert v.stdout.decode().strip()==expected
 assert all(sha(root/f)==h for f,h in before.items())
 artifacts=[check/'build/Vn8080_color_path',*check.glob('*.json'),*check.glob('*.log')]
 report={'scope':'Corrected connected related-Bandido controls and ideal pin logic; static MAME functional inference only.','actual_build_exit':receipts[0]['exit_code'],'actual_native_exit':receipts[1]['exit_code'],'result':expected,'source_sha256':before,'source_control_trace':'docs/evidence/sheriff_color_control_trace.json','withdrawn_report':'_checks/agent-color-control-20261010/superseded-assumption/docs/evidence/sheriff_color_path_native.json','withdrawn_claims':['O2/O3 swapped','4F output3 drives red A','3K nQ2 drives PROM NAND2'],'equations':{'D2':'NOT(O4 AND mode2_n)','nQ2':'held(O4 AND mode2_n)','S':'mode0 OR ((mode1 OR mode2) AND nQ2)','ST':'mode3','A':'OUT6 Q2:Q0','B':'{nQ3,nQ1,nQ4}','pnp_on':'mux_n AND video_bit'},'receipts':receipts,'artifact_sha256':{p.relative_to(root).as_posix():sha(p) for p in artifacts},'production_integrated':False,'physical_timing_qualified':False,'strict_graphics_gate_pass':False,'quartus_executed':False,'rbf_built':False}
 (root/'docs/evidence/sheriff_color_path_native.json').write_text(json.dumps(report,indent=2)+'\n',newline='');print(expected,flush=True)
if __name__=='__main__':main()
