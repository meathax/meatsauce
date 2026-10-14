#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Freeze, run and close the scoped current-board IRQ integration qualification."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess,sys
from datetime import datetime,timezone
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(p):
 with pathlib.Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
def receipt_command(out,name,argv,env=None):
 with (out/(name+'.stdout.log')).open('wb') as so,(out/(name+'.stderr.log')).open('wb') as se:r=subprocess.run(argv,stdout=so,stderr=se,env=env)
 v=dict(argv=argv,exit_code=r.returncode,finished_utc=datetime.now(timezone.utc).isoformat());write(out/(name+'.json'),v);print(json.dumps(dict(step=name,exit_code=r.returncode)),flush=True);return r.returncode
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--prepare',choices=['before','after']);p.add_argument('--build',choices=['before','after']);p.add_argument('--probe',choices=['before','after']);p.add_argument('--run',choices=['before','after']);p.add_argument('--close',action='store_true');a=p.parse_args();out=a.output.resolve();assert out.is_relative_to(ROOT)
compile_files=['rtl/n8080_board.sv','rtl/n8080_cpu.sv','rtl/n8080_vm80a_ce.v','rtl/n8080_mcs48.sv','rtl/vendor/t48/t48_core.v','rtl/sheriff_sn76477.sv','rtl/n8080_interrupt_path.sv','sim/board_harness.cpp']
if a.prepare:
 out.mkdir(parents=True,exist_ok=True);d=out/a.prepare;d.mkdir(exist_ok=True);source=d/'source';source.mkdir(exist_ok=True);assert not (d/'source.json').exists()
 tracked=(out/'snapshot-inventory.txt').read_text(encoding='utf8').splitlines()
 files={n for n in tracked if n and pathlib.Path(n).suffix.lower() in {'.sv','.v','.svh','.qip','.qsf','.qpf','.sdc','.cpp','.h','.hpp'}}
 files.update(compile_files+['files.qip','tools/qualify_board_irq_integration.py']);hashes={}
 for n in sorted(files):
  p=ROOT/n
  if not p.is_file():continue
  t=source/n;t.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,t);hashes[n]=sha(t);assert sha(p)==hashes[n],n
 identity=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest();write(d/'source.json',dict(source_identity=identity,source_sha256=hashes))
 fixtures=out/'fixtures';fixtures.mkdir(exist_ok=True)
 for name,original in [('sheriff.bin',ROOT/'roms/sheriff.bin'),('inputs_restart.csv',ROOT/'_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv')]:
  t=fixtures/name
  if not t.exists():shutil.copyfile(original,t)
  assert sha(t)==sha(original)
 write(fixtures/'source.json',{n:sha(fixtures/n) for n in ['sheriff.bin','inputs_restart.csv']});print(json.dumps(dict(prepared=a.prepare,source_identity=identity,files=len(hashes))),flush=True);sys.exit(0)
mode=a.build or a.probe or a.run
if mode:
 d=out/mode;source=d/'source';manifest=json.loads((d/'source.json').read_text())
 for n,h in manifest['source_sha256'].items():assert sha(source/n)==h,n
 obj=d/'obj';binary=obj/'Vn8080_board'
 if a.build:
  argv=['verilator','--cc','--exe','--build','--assert','--timing','--threads','1','--x-initial','unique','--x-assign','unique','-Wno-fatal','-j','2','--top-module','n8080_board','-Mdir',str(obj),'-I'+str(source/'rtl'),'-CFLAGS','-O2 -std=c++17']+[str(source/n) for n in compile_files]
  sys.exit(receipt_command(d,'build',argv))
 assert binary.read_bytes()[:4]==b'\x7fELF'
 if a.run:
  runtime=d/'native';runtime.mkdir(exist_ok=False);env=os.environ.copy();env['SHERIFF_BUS_FRAMES']='64,65,66'
  argv=[str(binary),str(out/'fixtures/sheriff.bin'),str(runtime),'68',str(out/'fixtures/inputs_restart.csv'),'+verilator+seed+1']
  code=receipt_command(d,'native',argv,env);r=json.loads((d/'native.json').read_text());r.update(source_identity=manifest['source_identity'],binary_sha256=sha(binary),frames_requested=68,fixture_sha256=json.loads((out/'fixtures/source.json').read_text()));write(d/'native.json',r);sys.exit(code)
 if a.probe:
  probe_source=out/'board_irq_probe.cpp';probe_binary=d/'board_irq_probe';inc=subprocess.check_output(['verilator','-getenv','VERILATOR_ROOT'],text=True).strip();runtime=[str(p) for p in [obj/'verilated.o',obj/'verilated_threads.o',obj/'verilated_timing.o'] if p.exists()]
  argv=['c++','-std=c++17','-O2','-I'+str(obj),'-I'+inc+'/include','-I'+inc+'/include/vltstd',str(probe_source),str(obj/'Vn8080_board__ALL.a'),*runtime,'-pthread','-latomic','-o',str(probe_binary)]
  code=receipt_command(d,'probe-build',argv)
  if code:sys.exit(code)
  assert probe_binary.read_bytes()[:4]==b'\x7fELF';code=receipt_command(d,'probe',[str(probe_binary),str(out/'fixtures/sheriff.bin'),str(d/'probe.csv'),mode,'+verilator+seed+1'])
  r=json.loads((d/'probe.json').read_text());r.update(observations=json.loads((d/'probe.stdout.log').read_text()) if code==0 else {},source_identity=manifest['source_identity'],binary_sha256=sha(probe_binary),observer_sha256=sha(probe_source),trace_sha256=sha(d/'probe.csv'));write(d/'probe.json',r);print(json.dumps(r['observations']),flush=True);sys.exit(code)
if a.close:
 before=out/'before';after=out/'after';bm=json.loads((before/'source.json').read_text());am=json.loads((after/'source.json').read_text());changed=[n for n,h in bm['source_sha256'].items() if am['source_sha256'].get(n)!=h];new=[n for n in am['source_sha256'] if n not in bm['source_sha256']]
 names=['cpu_startup.csv','io.csv','memory_writes.bin','sound.csv','bus.csv']+[f'frame_{f:05d}.{ext}' for f in [1,2,3,4,60,68] for ext in ['ram','ppm']]
 equal={n:dict(before_sha256=sha(before/'native'/n),after_sha256=sha(after/'native'/n),identical=sha(before/'native'/n)==sha(after/'native'/n)) for n in names}
 saved=ROOT/'_checks/first-irq66-boundary-20261010/native';saved_equal={n:dict(current_sha256=sha(after/'native'/n),saved_sha256=sha(saved/n),identical=sha(after/'native'/n)==sha(saved/n)) for n in names if (saved/n).exists()}
 receipts={mode:{kind:json.loads((out/mode/(kind+'.json')).read_text()) for kind in ['build','native','probe-build','probe']} for mode in ['before','after']}
 r=dict(scope='Actual current production board interrupt integration: paired cold parent-ROM68-field native captures and ordinary-pause pending-IRQ probe; existing raster/CPU origin preserved.',recorded_utc=datetime.now(timezone.utc).isoformat(),source_before=bm,source_after=am,changed_snapshot_sources=changed,new_snapshot_sources=new,fixture_sha256=json.loads((out/'fixtures/source.json').read_text()),receipts=receipts,same_side_68_field_comparison=equal,against_saved_first_irq68=saved_equal,main_cpu_ram_io_rgb_unchanged=all(v['identical'] for v in equal.values()),source_equations='docs/evidence/sheriff_irq_physical_path.json',source_equations_sha256=sha(ROOT/'docs/evidence/sheriff_irq_physical_path.json'),existing_first_irq_negative_preserved='docs/FIRST_IRQ_BOUNDARY.md field66 returnPC0ff3 vsMAME0fef remains; no source-origin offset chosen.',existing_first_irq_negative_sha256=sha(ROOT/'docs/FIRST_IRQ_BOUNDARY.md'),physical_origin_qualified=False,physical_reset_qualified=False,physical_timing_qualified=False,full_graphics_qualified=False,mame_equivalence_qualified=False,audio_qualified=False,quartus_executed=False,rbf_built=False,recovery=str(out.relative_to(ROOT)).replace('\\','/'))
 r['qualification_pass']=r['main_cpu_ram_io_rgb_unchanged'] and all(v['exit_code']==0 for m in receipts.values() for v in m.values()) and receipts['after']['probe']['observations'].get('pass') is True
 r['evidence_sha256']={str(p.relative_to(out)).replace('\\','/'):sha(p) for p in out.glob('*/*.json')}
 write(out/'terminal.json',r);write(ROOT/'docs/evidence/sheriff_board_irq_integration.json',r);print(json.dumps(dict(qualification_pass=r['qualification_pass'],same_side_all_equal=r['main_cpu_ram_io_rgb_unchanged'],changed_sources=changed,new_sources=new,saved_compatible_equal=all(v['identical'] for v in saved_equal.values()))));sys.exit(0 if r['qualification_pass'] else 1)
p.error('one operation required')
