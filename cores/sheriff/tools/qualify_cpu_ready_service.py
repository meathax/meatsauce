#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Qualify conditional native CPU READY/readback service on synthetic bus memory."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess,sys
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
out=a.output.resolve();assert out.is_relative_to(ROOT);out.mkdir(parents=True,exist_ok=False)
files=['rtl/n8080_cpu.sv','rtl/n8080_vm80a_ce.v','rtl/n8080_ram_readback.sv','rtl/n8080_memory_phases.sv','sim/cpu_ready_service_qualification.sv','sim/cpu_ready_service_qualification.cpp']
source=out/'source';source.mkdir();hashes={}
for n in files:
 target=source/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/n,target);hashes[n]=sha(target)
obj=out/'obj';argv=['verilator','--cc','--exe','--build','-j','2','-Wno-fatal','--top-module','cpu_ready_service_qualification','-Mdir',str(obj),'-CFLAGS','-std=c++17']+[str(source/n) for n in files]
started=datetime.now(timezone.utc).isoformat()
with (out/'build.stdout.log').open('wb') as so,(out/'build.stderr.log').open('wb') as se:build=subprocess.run(argv,stdout=so,stderr=se)
receipt=dict(scope='Actual CPU READY adapter + RAM readback + memory phase components; synthetic stable bus byte/write-release environment; conditional shared origin.',started_utc=started,source_sha256=hashes,build_argv=argv,build_exit_code=build.returncode,production_rtl_changed=False,quartus_executed=False,rbf_built=False)
write(out/'build.json',receipt)
if build.returncode:print(json.dumps(receipt));sys.exit(build.returncode)
binary=obj/'Vcpu_ready_service_qualification';assert binary.read_bytes()[:4]==b'\x7fELF';cases=[]
for origin in (0,5,10,15,20):
 trace=out/f'phase-{origin}.csv';native=subprocess.run([str(binary),str(origin),str(trace)],capture_output=True,text=True)
 (out/f'phase-{origin}.stdout.log').write_text(native.stdout);(out/f'phase-{origin}.stderr.log').write_text(native.stderr)
 case=dict(origin_phase=origin,exit_code=native.returncode,trace_sha256=sha(trace),stdout=native.stdout,stderr=native.stderr)
 try:case['observations']=json.loads(native.stdout)
 except json.JSONDecodeError:pass
 cases.append(case);print(json.dumps(case),flush=True)
receipt.update(finished_utc=datetime.now(timezone.utc).isoformat(),native_binary_sha256=sha(binary),cases=cases,
 qualification_pass=all(c['exit_code']==0 and c.get('observations',{}).get('pass') for c in cases),
 physics_qualified=False,mame_equivalence_qualified=False,production_integration_qualified=False,
 assumptions=['phi1TTL=NOT(phase<5); rounded phi3TTL=(phase<8 OR phase>=13).','Counter reset/release origins are named synthetic phase cases, not original-board reset alignment.','Host RAM byte stays valid for the addressed transaction; host write commits on WR release, not physical4116 WE/CAS/RAS.','Current readback old-state/nonblocking precedence is retained for coincident capture and phi3; no fitted delay.'])
write(out/'terminal.json',receipt);print(json.dumps({k:receipt[k] for k in ('scope','build_exit_code','qualification_pass','physics_qualified')}))
sys.exit(0 if receipt['qualification_pass'] else 1)
