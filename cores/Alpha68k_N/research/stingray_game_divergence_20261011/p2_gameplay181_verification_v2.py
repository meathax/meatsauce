import csv, hashlib, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

O=Path(__file__).resolve().parent
JOB=O/'p2_gameplay181';S=JOB/'source'
OBS=O/'native_observer181'
BASE=O.parent/'stingray_combined_stage/next_coupled_scope_v2'
PROP=O/'p2_candidate_qualification_v7'
INPUT=BASE/'gameplay_inputs.csv'
CANON=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
ROM=CANON/'roms/sstingry/download.bin'
REF=CANON/'sim/captures/sstingry/gameplay'
CAUSE=BASE/'first_buffer_cause'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def save(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8')
def wsl(p):return '/mnt/'+p.drive[0].lower()+str(p)[2:].replace('\\','/')
def read(p):return list(csv.DictReader(p.open(newline='',encoding='utf-8')))
def start(cmd,kind):
    assert not (JOB/(kind+'_job.json')).exists(),f'Duplicate {kind} refused'
    log=(JOB/(kind+'.log')).open('wb');p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
    save(JOB/(kind+'_job.json'),{'pid':p.pid,'worker_pid':os.getpid(),'started':time.time(),'command':cmd});return p,log
def finish(pair,kind):
    p,log=pair;code=p.wait();log.close();save(JOB/(kind+'_exit.json'),{'pid':p.pid,'worker_pid':os.getpid(),'exit_code':code,'finished':time.time(),'log':pin(JOB/(kind+'.log'))});return code
def prepare():
    assert not (JOB/'preparation.json').exists(),'Duplicate preparation refused'
    assert sha(PROP/'import_manifest.json')=='bc0af87993a78ba9ce95127f50b5324a5749e605b9c0227a9b138f92fa255334'
    assert sha(INPUT)=='20833903b9400168a62a83b7e2027aaae2a662ff12184e58c8622697a3608ee8'
    old=json.loads((OBS/'verification.json').read_text(encoding='utf-8'))
    assert all(x==0 for x in old['actual_exits'].values()) and len(old['native_all_snapshot_overlap'])==75
    shutil.copytree(OBS/'source',S,ignore=shutil.ignore_patterns('build'),dirs_exist_ok=False)
    changes={
        'rtl/alpha68kn_mcu.sv':('alpha68kn_mcu.sv','26614f565524e7dc136c3c898eb044807d22d2c6ce473dcc64d7f54258a97120'),
        'rtl/vendor/t48/t48_core.v':('t48_core.v','2ad3acf392e1deec18d5d7f2c8d878b33b00073c55a7c032cd0155dfac46bf6d')}
    for rel,(name,expected) in changes.items():
        donor=PROP/'candidate'/name;assert sha(donor)==expected;(S/rel).write_bytes(donor.read_bytes())
    closure=json.loads((BASE/'source_closure.json').read_text(encoding='utf-8'));entries=[]
    for row in closure['source_files']:
        rel=Path(row['path']).relative_to(BASE/'source');name=rel.as_posix();a=OBS/'source'/rel;b=S/rel
        if name not in changes:assert sha(a)==sha(b)
        entries.append({'relative':name,'combined_baseline_sha256':row['combined_sha256'],'observer_baseline_sha256':sha(a),'candidate_sha256':sha(b),'path':str(b),'profile2_functional_change':name in changes})
    assert len(entries)==75
    save(JOB/'source_closure.json',{'source_files':entries,'source_root':str(S),'functional_changed_files':list(changes),'readonly_observer_unchanged':True,'base_closure':pin(BASE/'source_closure.json'),'reviewed_proposal':pin(PROP/'import_manifest.json')})
    (S/'rtl/vendor/t48/SOURCE.proposed.json').write_bytes((PROP/'SOURCE.proposed.json').read_bytes())
    (S/'rtl/vendor/t48/LICENSE.upstream').write_bytes((PROP/'LICENSE.upstream').read_bytes())
    board=S/'rtl/alpha68kn_board.sv';text=board.read_text(encoding='utf-8')
    guards=['wire is_stingray=profile==8\'d2;', '.reset(held_reset || !is_stingray)',
            'wire sting_main_pause=is_stingray && sting_mcu_main_halt && mas_n;',
            'wire sting_mcu_work_service=is_stingray && !held_reset && sting_mcu_shared_write;',
            'assign sting_mcu_command_valid=is_stingray && ram_bus_service && !iack &&',
            'if(is_stingray && sting_mcu_irq2) irq2<=1;',
            'if(is_stingray && sting_mcu_control_event) flip<=sting_mcu_flip;']
    assert all(g in text for g in guards)
    instances=[]
    for p in S.rglob('*'):
        if p.suffix in ['.sv','.v'] and p.name!='t48_core.v':
            for match in re.finditer(r'\bt48_core\s+(\w+)\s*\(',p.read_text(encoding='utf-8')):instances.append({'path':str(p),'instance':match.group(1)})
    assert len(instances)==1 and Path(instances[0]['path'])==S/'rtl/alpha68kn_mcu.sv'
    save(JOB/'profile01_inactive_cone.json',{'scope':'Source-cone equivalence for World profile0/Japan profile1, not a new full gameplay or timing run.','board_exact':sha(board)==sha(OBS/'source/rtl/alpha68kn_board.sv'),'unchanged_source_files':73,'changed_source_files':list(changes),'sole_T48_instance':instances,'profile2_only_guards':[{'text':g,'line':text[:text.index(g)].count('\n')+1} for g in guards],'profiles01_MCU_held_reset':True,'profile01_CPU_pause_RAM_IRQ_flip_cones_exclude_MCU':True,'board':pin(board)})
    save(JOB/'preparation.json',{'closure':pin(JOB/'source_closure.json'),'original_input':pin(INPUT),'ROM':pin(ROM),'host_observer':pin(S/'sim/system_main.cpp'),'observer_config':pin(S/'sim/coupled_observer.vlt'),'profile01_proof':pin(JOB/'profile01_inactive_cone.json'),'helper':pin(Path(__file__)),'authorization':'Root reviewed P2 proposal and independent review; exactly one privatejoined181 using original phase CSV, genuine ROM and existing readonly accepted-input/MCU observer; no1800/production changes.'})

def scan_owned():
    cmds={
      'native':['wsl.exe','-d','Ubuntu','--exec','/bin/ps','-eo','pid,ppid,etime,args'],
      'windows':['powershell.exe','-NoProfile','-Command',"Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'p2_gameplay181|alpha68kn_system_sim' } | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Depth 3"]}
    result={}
    for name,cmd in cmds.items():
        p=subprocess.run(cmd,capture_output=True);assert p.returncode==0
        out=p.stdout.decode('utf-8',errors='replace')
        if name=='native':out='\n'.join(l for l in out.splitlines() if 'alpha68kn_system_sim' in l or 'p2_gameplay181' in l)
        result[name]={'exit_code':p.returncode,'stdout':out,'stderr':p.stderr.decode(errors='replace')}
    owned_native=[l for l in result['native']['stdout'].splitlines() if wsl(JOB/'capture') in l and 'alpha68kn_system_sim' in l]
    assert not owned_native,'Existing owned gameplay replay found; duplicate refused'
    save(JOB/'owned_jobscan.json',{'worker_pid':os.getpid(),'observed':time.time(),'owned_native_runs':owned_native,'scans':result})

def verify():
    capture=JOB/'capture'
    applied=read(capture/'applied_inputs.csv');inputs=read(INPUT)
    assert len(applied)==182 and len(inputs)>=181
    input_errors=[]
    for row,expected in zip(applied[1:],inputs):
        if [row[k] for k in ['controls','dips','coins_n']]!=[expected[k] for k in ['in0','in1','in2']] or row['frame']!=expected['frame']:input_errors.append(row['frame'])
    assert not input_errors
    proof=json.loads((CAUSE/'verification.json').read_text(encoding='utf-8'));pins=proof['completed_RGB_pins'];pins=pins.values() if isinstance(pins,dict) else pins
    comparisons=[]
    for item in pins:
        ref=Path(item['path']);assert sha(ref)==item['sha256'];frame=int(re.search(r'frame_(\d+)',ref.name).group(1));p=capture/f'frame_{frame:06d}.rgb'
        a=p.read_bytes();b=ref.read_bytes();assert len(a)==len(b)==172032
        d={'frame':frame,'completed_MAME':pin(ref),'native':pin(p),'RGB_different_pixels':sum(a[i:i+3]!=b[i:i+3] for i in range(0,len(a),3))}
        for suffix in ['work.bin','sprites.bin']:
            n=capture/f'frame_{frame:06d}.{suffix}';r=REF/f'frame_{frame:06d}.{suffix}';nb=n.read_bytes();rb=r.read_bytes();assert len(nb)==len(rb)
            d[suffix]={'different_bytes':sum(x!=y for x,y in zip(nb,rb)),'native':pin(n),'MAME':pin(r)}
        comparisons.append(d)
    native=read(capture/'accepted_inputs.csv');mame=read(OBS/'mame181/accepted_reads.csv');coin=read(capture/'coin_samples.csv')
    assert all(int(r['t0_sample'])==(int(r['coins_n'])&1) and int(r['t1_sample'])==((int(r['coins_n'])>>1)&1) for r in coin)
    starts=[r for r in native if int(r['address'])==0xc0000 and int(r['frame'])>=159]
    credits=[r for r in native if int(r['address'])==0x20044 and int(r['data_in_after'])&255]
    save(JOB/'verification.json',{'scope':'One real CPU/Z80/8748 native181 replay with reviewed P2 transaction fix and original prepared input phase; finite gate only.','actual_exits':{k:json.loads((JOB/(k+'_exit.json')).read_text(encoding='utf-8'))['exit_code'] for k in ['build','run']},'source_closure_exact_post':all(sha(Path(r['path']))==r['candidate_sha256'] for r in json.loads((JOB/'source_closure.json').read_text(encoding='utf-8'))['source_files']),'ROM_exact_post':sha(ROM)==json.loads((JOB/'preparation.json').read_text(encoding='utf-8'))['ROM']['sha256'],'originalCSV_applied_rows_exact':not input_errors,'accepted_native_rows':len(native),'reference_actual_read_rows':len(mame),'T48_coin_branch_samples':len(coin),'T0_T1_consumption_exact':True,'comparisons':sorted(comparisons,key=lambda r:r['frame']),'actual_start_reads':starts,'actual_positive_credit_reads':credits,'all5_completed_RGB_exact':all(r['RGB_different_pixels']==0 for r in comparisons),'whole_game_pass':False,'timing_resources_hardware_pass':False})
    print(json.dumps({'comparison':[{k:r[k] for k in ['frame','RGB_different_pixels']} for r in comparisons],'positive_credit_reads':len(credits),'actual_start_reads':len(starts)}),flush=True)

def worker():
    prepare()
    assert finish(start(['wsl.exe','-d','Ubuntu','--cd',str(S),'--exec','/bin/bash','sim/build_system.sh'],'build'),'build')==0
    elf=S/'sim/build/alpha68kn_system_sim';save(JOB/'ELF.json',pin(elf))
    scan_owned()
    cmd=['wsl.exe','-d','Ubuntu','--cd',str(elf.parent),'--exec','/bin/bash','-c','printf "linux_pid=%s\\n" "$$"; exec "$@"','p2gameplay181','./alpha68kn_system_sim',wsl(ROM),'181',wsl(JOB/'capture'),'gameplay','--inputs',wsl(INPUT)]
    admission={'created':time.time(),'worker_pid':os.getpid(),'frames':181,'launch_count':1,'command':cmd,'ELF':pin(elf),'closure':pin(JOB/'source_closure.json'),'preparation':pin(JOB/'preparation.json'),'owned_jobscan':pin(JOB/'owned_jobscan.json'),'ROM':pin(ROM),'input':pin(INPUT),'output':str(JOB/'capture'),'reference_actual_reads':pin(OBS/'mame181/accepted_reads.csv'),'completedRGB_proof':pin(CAUSE/'verification.json')}
    save(JOB/'admission.json',admission)
    assert not (JOB/'run_job.json').exists()
    code=finish(start(cmd,'run'),'run')
    assert code==0
    verify();save(JOB/'verification_exit.json',{'exit_code':0,'worker_pid':os.getpid(),'finished':time.time()})

if __name__=='__main__':
    if '--worker' in sys.argv:
        try:worker()
        except Exception as exc:
            save(JOB/'worker_failure.json',{'type':type(exc).__name__,'message':str(exc),'worker_pid':os.getpid(),'finished':time.time()});raise
    elif '--verify' in sys.argv:verify()
    else:
        assert not (JOB/'worker.json').exists(),'Duplicate worker refused';JOB.mkdir(exist_ok=True)
        with (JOB/'worker.log').open('wb') as log:p=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__).resolve()),'--worker'],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW|subprocess.CREATE_NEW_PROCESS_GROUP)
        save(JOB/'worker.json',{'pid':p.pid,'started':time.time(),'helper':pin(Path(__file__))});print('Registered one P2 gameplay181 worker',p.pid,flush=True)
