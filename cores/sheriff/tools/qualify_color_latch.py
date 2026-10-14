#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Qualify the joined actual counter/3K CE without a generated clock."""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,subprocess
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 args=argparse.ArgumentParser();args.add_argument('--attempt');args.add_argument('--reuse-build',action='store_true');args=args.parse_args()
 assert not args.reuse_build or args.attempt
 if args.attempt:assert args.attempt.replace('-', '').isalnum()
 root=Path(__file__).resolve().parents[1];base_check=root/'_checks/color-latch-20261010';check=base_check/args.attempt if args.attempt else base_check;check.mkdir(exist_ok=False)
 linux='/mnt/'+root.drive[0].lower()+root.as_posix()[2:];build=linux+'/_checks/color-latch-20261010/build'
 files=['rtl/n8080_memory_phases.sv','rtl/n8080_horizontal_counter.sv','rtl/n8080_color_latch.sv','sim/color_latch_qualification.sv','sim/color_latch_qualification.cpp','tools/qualify_color_latch.py']
 hashes={f:sha(root/f) for f in files};base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
 commands=[base+['verilator','--cc','--exe','--build','--top-module','color_latch_qualification','--Mdir',build,'--threads','1','-j','2','-Wno-fatal',*files[:4],linux+'/'+files[4]],base+[build+'/Vcolor_latch_qualification']]
 if args.reuse_build:
  old=json.loads((base_check/'initial-negative/source_sha256.json').read_text())
  assert all(sha(root/f)==old[f] for f in files[:4])
  commands[0]=base+['make','-C',build,'-f','Vcolor_latch_qualification.mk','-j','2']
 receipts=[]
 for stage,command in zip(['build','native'],commands):
  start=datetime.now(timezone.utc).isoformat();r=subprocess.run(command,capture_output=True)
  (check/(stage+'.stdout.log')).write_bytes(r.stdout);(check/(stage+'.stderr.log')).write_bytes(r.stderr)
  receipt={'command':command,'start_utc':start,'finish_utc':datetime.now(timezone.utc).isoformat(),'exit_code':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')}
  (check/(stage+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n',newline='');receipts.append(receipt)
  print(stage+' exit='+str(r.returncode),flush=True)
  assert r.returncode==0,receipt['stderr'][-2500:]
 expected='PASS counter_pixels=10240 QD_captures=32 capture_values=16 CE_hold_checks=92160'
 assert receipts[1]['stdout'].strip()==expected
 assert all(sha(root/f)==h for f,h in hashes.items())
 report={'scope':'Joined related-Bandido 4J QD clock-enable and ideal LS175 capture/retention; not production scanout/DRAM/power-up/electrical timing.','actual_build_exit':receipts[0]['exit_code'],'actual_native_exit':receipts[1]['exit_code'],'result':expected,'source_sha256':hashes,'receipts':receipts,'artifact_sha256':{p.relative_to(root).as_posix():sha(p) for p in [base_check/'build/Vcolor_latch_qualification',*check.glob('*-receipt.json'),*check.glob('*.log')]},'production_integrated':False,'physical_timing_qualified':False,'strict_graphics_gate_pass':False,'quartus_executed':False,'rbf_built':False}
 (root/'docs/evidence/sheriff_color_latch_native.json').write_text(json.dumps(report,indent=2)+'\n',newline='');print(expected)
if __name__=='__main__':main()
