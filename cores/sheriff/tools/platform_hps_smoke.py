import argparse, csv, hashlib, json, os, shutil, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description='Run a short HPS smoke from an existing immutable frozen-source.json.')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
OUT=args.output.resolve()
assert OUT.is_relative_to(ROOT), 'Output must remain inside the core'
assert (OUT/'frozen-source.json').is_file(), 'Prepare the immutable source image first'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,j): p.write_text(json.dumps(j,indent=2)+'\n')
frozen=json.loads((OUT/'frozen-source.json').read_text())
PREV=ROOT/'_checks/current-wrapper-gameplay-1201-20261010/run-v3'
receipt=json.loads((PREV/'receipt.json').read_text()); old=json.loads((PREV/'observer-build.json').read_text())
assert old['exit_code']==0
for n,d in receipt['source_sha256'].items():
    assert sha(OUT/'frozen-source'/n)==d,n
for n,d in old['objects_sha256'].items(): assert sha(n)==d,n
model=OUT/'frozen-model'; model.mkdir(exist_ok=False)
obj=ROOT/'.preflight/cache/obj'
model_hashes={}
for p in obj.iterdir():
    if p.suffix in ('.h','.hpp','.cpp','.o','.v','.sv','.dat'):
        shutil.copyfile(p,model/p.name); model_hashes[p.name]=sha(model/p.name)
objects={}
for n,d in old['objects_sha256'].items():
    p=Path(n); target=model/p.name
    if not target.exists(): shutil.copyfile(p,target)
    assert sha(target)==d; objects[n]=str(target)
header=(model/'Vpf_tb___024root.h').read_text()
fields=['ioctl_download','ioctl_wr','loading','rom_loaded','reset_stretch','ioctl_index','ioctl_addr','joy0','joy1']
for f in fields: assert 'pf_tb__DOT__emu__DOT__'+f+';' in header,f
pc='pf_tb__DOT__emu__DOT__board__DOT__processor__DOT__cpu__DOT__r16_pc'
assert pc+';' in header
source=(PREV/'observed-harness.cpp').read_text(); assert sha(PREV/'observed-harness.cpp')==receipt['private_harness_sha256']
source=source.replace('    FILE* input_observation=', '''    FILE* platform_observation=openf("platform_probe.csv","w");
    fprintf(platform_observation,"ns,download,wr,loading,loaded,stretch,index,addr,joy0,joy1,pc\\n");
    bool platform_last_wr=false;double platform_next_ns=0;
    FILE* input_observation=''',1)
params=','.join('r->pf_tb__DOT__emu__DOT__'+f for f in fields)+',r->'+pc
hook='''
        if(now_ns()>=platform_next_ns || (r->pf_tb__DOT__emu__DOT__ioctl_wr&&!platform_last_wr)){
            fprintf(platform_observation,"%.0f,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u\\n",now_ns(),PARAMS);
            platform_next_ns=now_ns()+10000;
        }
        platform_last_wr=r->pf_tb__DOT__emu__DOT__ioctl_wr;
        if(now_ns()>=30000000)g_stop=true;
'''.replace('PARAMS',params)
source=source.replace('        const auto* r=top->rootp;', '        const auto* r=top->rootp;'+hook)
source=source.replace('    top->final();','    fclose(platform_observation);\n    top->final();')
private=OUT/'platform-probe.cpp'; private.write_text(source)
binary=OUT/'platform-probe.exe'
argv=[]
for a in old['argv']:
    if a in objects: a=objects[a]
    elif a==str(PREV/'observed-harness.cpp'): a=str(private)
    elif a.startswith('-I') and Path(a[2:]).resolve()==obj.resolve(): a='-I'+str(model)
    elif a==str(PREV/'observed-pfsim.exe'): a=str(binary)
    argv.append(a)
assert str(private) in argv and argv[-1]==str(binary)
sys.path.insert(0,'D:/Arcade/AI/MISTERDEBUG/src')
from preflight import build,util
util.setup_env(); env=os.environ.copy(); compiler=build.cxx_compiler(env); argv[0]=str(compiler)
with (OUT/'compile.stdout.log').open('wb') as so,(OUT/'compile.stderr.log').open('wb') as se:
    cp=subprocess.run(argv,env=env,stdout=so,stderr=se,creationflags=subprocess.CREATE_NO_WINDOW)
write(OUT/'platform-compile.json',dict(exit_code=cp.returncode,argv=argv,private_harness_sha256=sha(private),frozen_model_sha256=model_hashes,objects_sha256={Path(k).name:sha(v) for k,v in objects.items()}))
assert cp.returncode==0
run=OUT/'runtime'; run.mkdir(); (run/'frames').mkdir()
boot=(PREV/'boot.script').read_text().split('mark boot_done')[0]
romdir=OUT/'private-roms'; romdir.mkdir()
for i in (0,3):
    p=ROOT/f'.preflight/cache/roms/rom_{i}.bin'; target=romdir/p.name;shutil.copyfile(p,target)
    boot=boot.replace(str(p),str(target))
# Fresh ordinary HPS sequence: start execution, explicit reset, release again,
# centered analog and simultaneous player digital inputs. No internal RTL writes.
for cmd in (0x1a,0x3d):
    for player in (0,1): boot+=f'uio {cmd:#x} {player} 0\n'
boot+='mark boot_done\nwait_us 2000\nuio 0x02 0x91 0\nuio 0x03 0x200 0\nwait_us 1000\nuio 0x1e 1 0 0 0 0 0 0 0\nwait_us 1000\nuio 0x1e 0 0 0 0 0 0 0 0\nwait_us 1000\nuio 0x02 0 0\nuio 0x03 0 0\nwait_us 1000\nmark smoke_done\n'
(run/'boot.script').write_text(boot)
cfg=(ROOT/'.preflight/runs/20261010-054834/sim/hostile-s1/run.cfg').read_text()
cfg=cfg.replace('frames_after_boot=1201','frames_after_boot=2').replace('max_frames=3000','max_frames=4').replace('save_every=60','save_every=1').replace(str(ROOT),str(OUT/'frozen-source'))
(run/'run.cfg').write_text(cfg)
started=datetime.now(timezone.utc).isoformat()
with (run/'stdout.log').open('wb') as so,(run/'stderr.log').open('wb') as se:
    native=subprocess.run([str(binary),'+pf_dir='+str(run),'+verilator+rand+reset+2','+verilator+seed+1'],env=env,stdout=so,stderr=se,timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
rows=list(csv.DictReader((run/'platform_probe.csv').open()))
rows=[{k:int(v) for k,v in r.items()} for r in rows]
loading=[r for r in rows if r['loading']]
ready=[r for r in rows if r['loaded'] and r['stretch']==255]
# Count distinct observed writes per transfer while loader keeps CPU reset.
addresses=sorted({r['addr'] for r in rows if r['wr'] and r['index']==0})
resets=[r for r in rows if r['loaded'] and r['stretch']==0 and r['ns']>4000000]
checks=dict(native_exit_zero=native.returncode==0,
    rom_loader_observed=bool(loading),loading_keeps_reset=all(r['stretch']==0 for r in loading),
    downloaded_all_rom_addresses=addresses==list(range(0x4800)),
    first_execution_observed=bool(ready) and len({r['pc'] for r in ready})>10,
    ordinary_player_inputs=any(r['joy0']==0x91 and r['joy1']==0x200 for r in ready),
    explicit_hps_reset_observed=bool(resets),reset_holds_pc=all(r['pc']==0 for r in resets[1:]),
    execution_resumes_after_reset=bool(resets) and len({r['pc'] for r in ready if r['ns']>resets[-1]['ns']})>10)
result=dict(scope='Frozen real full MiSTer wrapper: ordinary HPS parent ROM/config download, initial execution, HPS reset/release and fresh digital input smoke; <=30ms.',
    source_identity=frozen['source_identity'],source_sha256=frozen['source_sha256'],
    reused_model_source_sha256=receipt['source_sha256'],connected_saved_sources_match=True,
    additional_frozen_sources=sorted(set(frozen['source_sha256'])-set(receipt['source_sha256'])),
    model_reuse_receipt=str(PREV/'observer-build.json'),compile_exit_code=cp.returncode,native_exit_code=native.returncode,
    started_utc=started,finished_utc=datetime.now(timezone.utc).isoformat(),checks=checks,
    observations=len(rows),rom_write_addresses=len(addresses),
    first_ready_ns=ready[0]['ns'] if ready else None,
    smoke_pass=all(checks.values()),full_wrapper_acceptance_pass=False,mame_equivalence_qualified=False,
    timing_resource_pass=False,rbf_built=False,state_forced=False,platform_models_changed=False,
    evidence_sha256={str(p.relative_to(ROOT)):sha(p) for p in (private,binary,run/'boot.script',run/'run.cfg',run/'platform_probe.csv',OUT/'platform-compile.json')},
    limitations=['Exact frozen saved connected172-source model scope; not acceptance of later source edits.','No long gameplay, pixel/audio equivalence, broader lifecycle, gamma/hiscore rerun or hardware qualification.'])
write(OUT/'platform-terminal.json',result)
print(json.dumps({k:result[k] for k in ('scope','source_identity','compile_exit_code','native_exit_code','checks','observations','rom_write_addresses','smoke_pass','additional_frozen_sources')}),flush=True)
sys.exit(0 if result['smoke_pass'] else 1)
