"""One isolated current-source build/test; no CPU replay, production edits or Quartus."""
from pathlib import Path
import hashlib,json,os,subprocess,time,shutil,tempfile
B=Path(__file__).resolve().parent
S=B/"v2"
R=B.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(n,d):(S/(n+'.json')).write_text(json.dumps(d,indent=2)+'\n')
def main():
 if os.name=='nt':
  assert not S.exists(),'Never restart completed/active v2';S.mkdir()
  for n in ['probe_top.sv','pitch_main.cpp']:shutil.copy2(B/n,S/n)
  assert not (S/'launcher.json').exists(),'Do not restart an existing isolated worker'
  cmd=['wsl.exe','-d','Ubuntu','--cd',str(R),'--exec','python3','research/ym2203_ssg_pitch_stage/prepare_v2.py']
  with (S/'launcher.log').open('w') as log:
   p=subprocess.Popen(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  save('launcher',{'actual_wsl_pid':p.pid,'command':cmd,'script_sha256':sha(Path(__file__))});print(p.pid);return 0
 assert not (S/'job.json').exists(),'Do not restart an existing isolated worker'
 C=Path('/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
 compiled=R/'research/kyros_merged_lifecycle_v2_compiled_exit.json'
 cp=json.loads(compiled.read_text());assert cp['exit_code']==0
 files=[C/'rtl/alpha68kn_soundchips.sv']
 for pat in ['rtl/vendor/jt12/hdl/*.v','rtl/vendor/jt12/jt49/hdl/*.v','rtl/vendor/ay49/hdl/*.v']:files.extend(sorted(C.glob(pat)))
 assert len({p.name for p in files})==len(files)
 pins={str(p.relative_to(C)):sha(p) for p in files}
 assert all(cp['production_source_pins'][p]==h for p,h in pins.items()),'Chip graph differs from actual current compiled image'
 build=Path(tempfile.mkdtemp(prefix='alpha68kn-ymssg-pitch.',dir='/mnt/d/vibes/fpga/temp'))
 for p in files+[S/'probe_top.sv',S/'pitch_main.cpp']:shutil.copy2(p,build/p.name)
 references={}
 for rel in ['3rdparty/ymfm/src/ymfm_ssg.cpp','3rdparty/ymfm/src/ymfm_opn.cpp']:
  p=Path('/mnt/d/Arcade/AI/mame289')/rel;references[rel]=sha(p)
 save('source_contract',{'production_source_pins':pins,'compiled_receipt_sha256':sha(compiled),'MAME_source_pins':references,
  'master_Hz':48000000,'chip_enable_divider':24,'default_SSG_prescaler':4,'JT49_DIV':2,'tone_halfcycle_divider':4,
  'nominal_formula':'chip_Hz / (4*4*2*max(period,1)) = 62500/max(period,1) Hz; rising-gap 768*max(period,1) masterticks',
  'source_references':['alpha68kn_soundchips.sv phase0/reset/divider24','jt12_top.v80,461-475 JT49_DIV2 and SEL1','jt12_div.v52-71 resetSSGprescaler4','jt49_cen.v34-50 CLKDIV2','jt49_div.v37-48 tone and period0 override','MAME ymfm_ssg.cpp135-142 tone period0 counter handling','MAME ymfm_opn.cpp900-905,934 defaultSSG ratio4:1 at chipclock/4 output'],
  'adapter':'Read-only hierarchy outputs from unchanged production wrapper; no forced register/CPU state.'})
 version=subprocess.check_output(['/usr/local/bin/verilator','--version'],text=True).strip();assert version.startswith('Verilator 5.050 ')
 cmd=['/usr/local/bin/verilator','--cc','--exe','--build','-j','2','-O3','--assert','--no-assert-case','-Wno-fatal','--top-module','alpha68kn_ymssg_pitch_probe','--Mdir','obj','-o','ym2203_ssg_pitch_sim','probe_top.sv']+[p.name for p in files]+[str(build/'pitch_main.cpp'),'-CFLAGS','-O3 -std=c++17']
 job={'actual_worker_pid':os.getpid(),'started':time.time(),'production_source_pins':pins,'source_contract_sha256':sha(S/'source_contract.json'),
  'probe_sha256':sha(S/'probe_top.sv'),'host_sha256':sha(S/'pitch_main.cpp'),'script_sha256':sha(Path(__file__)),'verilator_version':version,'build_command':cmd,
  'build_root':str(build),'scope':'One isolated current actual donor/production-wrapper tone measurement; no game replay or production edit. v1 space-path build failure retained.'}
 with (S/'build.log').open('w') as log:
  p=subprocess.Popen(cmd,cwd=build,stdout=log,stderr=subprocess.STDOUT);job['actual_build_pid']=p.pid;save('job',job);code=p.wait()
 save('build_exit',{**job,'exit_code':code,'ended':time.time(),'build_log_sha256':sha(S/'build.log')})
 if code:return code
 assert all(sha(C/p)==h for p,h in pins.items()),'Production chip source changed during private build'
 exe=build/'obj/ym2203_ssg_pitch_sim';job['actual_ELF_sha256']=sha(exe)
 with (S/'run.log').open('w') as log:
  p=subprocess.Popen([str(exe)],cwd=build,stdout=log,stderr=subprocess.STDOUT);job['actual_simulation_pid']=p.pid;save('run_job',job);code=p.wait()
 cases=[]
 for line in (S/'run.log').read_text().splitlines():
  if line.startswith('{'):cases.append(json.loads(line))
 save('run_exit',{**job,'exit_code':code,'ended':time.time(),'run_log_sha256':sha(S/'run.log'),'actual_case_results':cases,
  'scope':'Actual isolated terminal and nominal comparison; period0 failure is retained rather than excused; not whole audio/game acceptance.'})
 print(json.dumps({'actual_build_exit':0,'actual_run_exit':code,'cases':cases}));return code
if __name__=='__main__':raise SystemExit(main())
