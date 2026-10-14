#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bounded native READY qualification; no whole-board graphics claim."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib,json,subprocess
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 root=Path(__file__).resolve().parents[1]
 check=root/'_checks/agent-root-ready-20261010';check.mkdir(exist_ok=False)
 files=['rtl/n8080_vm80a_ce.v','rtl/n8080_cpu.sv','sim/cpu_ready_qualification.sv','sim/cpu_ready_qualification.cpp','tools/qualify_cpu_ready.py']
 hashes={f:sha(root/f) for f in files}
 linux='/mnt/'+root.drive[0].lower()+root.as_posix()[2:]
 build=linux+'/_checks/agent-root-ready-20261010/build'
 base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
 commands=[base+['verilator','--cc','--exe','--build','--top-module','cpu_ready_qualification','--Mdir',build,'--threads','1','-j','2','-Wno-fatal',*files[:3],linux+'/'+files[3]],base+[build+'/Vcpu_ready_qualification']]
 receipts=[]
 for stage,command in zip(['build','native'],commands):
  start=datetime.now(timezone.utc).isoformat();r=subprocess.run(command,capture_output=True)
  (check/(stage+'.stdout.log')).write_bytes(r.stdout);(check/(stage+'.stderr.log')).write_bytes(r.stderr)
  receipt={'command':command,'start_utc':start,'finish_utc':datetime.now(timezone.utc).isoformat(),'exit_code':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')}
  (check/(stage+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n',newline='');receipts.append(receipt)
  print(stage+' exit='+str(r.returncode),flush=True)
  assert r.returncode==0,receipt['stderr'][-1800:]
 assert receipts[1]['stdout'].startswith('PASS release_phases=25 read_resume_cases=25 deferred_IRQ_cases=25 ')
 assert all(sha(root/f)==h for f,h in hashes.items())
 report={'scope':'Actual vm80a CE adapter: memory-read WAIT/resume at 25 release phases; IRQ deferred until READY release; constant-high facade pin equivalence. Synthetic component program; no PCB READY service, production-memory integration, whole-board graphics or fit claim.','actual_build_exit':receipts[0]['exit_code'],'actual_native_exit':receipts[1]['exit_code'],'result':receipts[1]['stdout'].strip(),'source_sha256':hashes,'receipts':receipts,'artifact_sha256':{p.relative_to(root).as_posix():sha(p) for p in [check/'build/Vcpu_ready_qualification',*check.glob('*-receipt.json'),*check.glob('*.log')]},'physical_memory_integrated':False,'strict_graphics_gate_pass':False,'quartus_executed':False,'rbf_built':False}
 (root/'docs/evidence/sheriff_cpu_ready_native.json').write_text(json.dumps(report,indent=2)+'\n',newline='')
 print(report['result'])
if __name__=='__main__':main()
