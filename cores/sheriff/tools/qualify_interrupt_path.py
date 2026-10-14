#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Freeze and qualify the isolated interrupt path with synthetic counter origin."""
import argparse,hashlib,json,pathlib,shutil,subprocess,sys
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--prepare-only',action='store_true');a=p.parse_args()
out=a.output.resolve();assert out.is_relative_to(ROOT)
files=['rtl/n8080_interrupt_path.sv','rtl/n8080_horizontal_counter.sv','rtl/n8080_vertical_counter.sv','sim/interrupt_path_qualification.sv','sim/interrupt_path_qualification.cpp']
if a.prepare_only:
 out.mkdir(parents=True,exist_ok=False);source=out/'source';source.mkdir();hashes={}
 for n in files+['tools/qualify_interrupt_path.py']:
  target=source/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/n,target);hashes[n]=sha(target)
 identity=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 write(out/'source.json',dict(source_sha256=hashes,source_identity=identity));print(json.dumps(dict(source_identity=identity,files=len(hashes))));sys.exit(0)
manifest=json.loads((out/'source.json').read_text());source=out/'source'
for n,h in manifest['source_sha256'].items():assert sha(source/n)==h,n
obj=out/'obj';argv=['verilator','--cc','--exe','--build','-j','2','-Wno-fatal','--top-module','interrupt_path_qualification','-Mdir',str(obj),'-CFLAGS','-std=c++17']+[str(source/n) for n in files]
started=datetime.now(timezone.utc).isoformat()
with (out/'build.stdout.log').open('wb') as so,(out/'build.stderr.log').open('wb') as se:build=subprocess.run(argv,stdout=so,stderr=se)
r=dict(scope='Native isolated IRQ path + qualified horizontal/vertical components; explicit synthetic CK/4 CE and counter-zero/VB-high origin.',started_utc=started,source_identity=manifest['source_identity'],source_sha256=manifest['source_sha256'],build_argv=argv,build_exit_code=build.returncode,production_integration_qualified=False,physical_origin_qualified=False,physical_timing_qualified=False,mame_equivalence_qualified=False,quartus_executed=False,rbf_built=False)
write(out/'build.json',r)
if build.returncode:print(json.dumps(r));sys.exit(build.returncode)
binary=obj/'Vinterrupt_path_qualification';assert binary.read_bytes()[:4]==b'\x7fELF'
native=subprocess.run([str(binary),str(out/'events.csv')],capture_output=True,text=True)
(out/'native.stdout.log').write_text(native.stdout,encoding='utf8',newline='\n');(out/'native.stderr.log').write_text(native.stderr,encoding='utf8',newline='\n')
try:observations=json.loads(native.stdout)
except json.JSONDecodeError:observations={}
r.update(finished_utc=datetime.now(timezone.utc).isoformat(),native_exit_code=native.returncode,native_binary_format='Linux ELF',native_binary_sha256=sha(binary),observations=observations,qualification_pass=native.returncode==0 and observations.get('pass') is True,recovery=str(out.relative_to(ROOT)).replace('\\','/'),source_trace='docs/evidence/sheriff_irq_physical_path.json',source_trace_sha256=sha(ROOT/'docs/evidence/sheriff_irq_physical_path.json'),assumptions=['sample_ce observes settled rawV/VB; the joined upstream register changes are consumed at the next master sample, not an asserted PCB propagation delay.','diagnostic_clear is a bench origin and is separate from CPU RESET.','status_inta clear dominates requests and applies at every master sample including sample_ce low.','Combinational glitches, asynchronous sub-master pulses, INTE setup/hold and C20/interconnect delay are unqualified.','Live interrupt_data is not latched on request; exact Sheriff PCB applicability remains conditional.'])
r['evidence_sha256']={n:sha(out/n) for n in ['source.json','build.json','build.stdout.log','build.stderr.log','native.stdout.log','native.stderr.log','events.csv']}
write(out/'terminal.json',r);write(ROOT/'docs/evidence/sheriff_irq_path_native.json',r)
print(json.dumps({k:r[k] for k in ['source_identity','build_exit_code','native_exit_code','qualification_pass','observations']}));sys.exit(0 if r['qualification_pass'] else 1)
