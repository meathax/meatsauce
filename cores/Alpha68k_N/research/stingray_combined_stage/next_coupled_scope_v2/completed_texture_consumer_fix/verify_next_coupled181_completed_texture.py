"""One terminal qualification plus bounded existing frame0 diagnosis, no replay."""
from pathlib import Path
import csv
import hashlib
import json
import os
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
SCOPE=HERE/'next_coupled_scope_v2'
JOB=SCOPE/'coupled181'
CAN=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def rows(p):
    with p.open() as f:return list(csv.DictReader(f))
def entry(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def comparison(a,b,rgb=False):
    x=a.read_bytes();y=b.read_bytes();assert len(x)==len(y)
    points=[(i//3%256,i//3//256) for i in range(0,len(x),3) if x[i:i+3]!=y[i:i+3]] if rgb else []
    return {'native':entry(a),'MAME':entry(b),'exact':x==y,'different_bytes':sum(p!=q for p,q in zip(x,y)),
       'different_RGB_pixels':len(points) if rgb else None,
       'difference_bbox':None if not points else [min(p for p,q in points),min(q for p,q in points),max(p for p,q in points),max(q for p,q in points)]}

def diagnose_zero():
    out=SCOPE/'frame0_diagnosis.json';assert not out.exists(),'Preserve the bounded diagnosis.'
    old=HERE/'coupled_boot111/capture';ref=CAN/'sim/captures/sstingry/attract'
    rgb=comparison(old/'frame_000000.rgb',ref/'frame_000000.rgb',True)
    strip=comparison(old/'frame_000000.sprites.bin',ref/'frame_000000.sprites.bin')
    work=comparison(old/'frame_000000.work.bin',ref/'frame_000000.work.bin')
    frames=rows(old/'frames.csv');accepted=[]
    with (ref/'events.csv').open() as f:
        for r in csv.DictReader(f):
            if int(r['frame'])>0:break
            if r['area'] in ['positions','tiles']:accepted.append(r)
    native=old/'frame_000000.rgb';mame=ref/'frame_000000.rgb'
    a=native.read_bytes();b=mame.read_bytes();pairs={}
    for i in range(0,len(a),3):
        if a[i:i+3]!=b[i:i+3]:
            key=a[i:i+3].hex()+'->'+b[i:i+3].hex();pairs[key]=pairs.get(key,0)+1
    record={'schema':'sstingry_frame0_finite_existing_diagnosis_v1','RGB':rgb,'strip':strip,'work':work,
      'changed_colors':pairs,'native_actual_frame0':frames[0],
      'native_accepted_strip_writes_at_frame0':int(frames[0]['strip_writes']),
      'retained_MAME_frame0_position_tile_write_rows':accepted,
      'atomic_vs_raster_assessment':'Native field0 ends with zero accepted strip writes. MAME/native final strip snapshots are byte-exact; default positions/tiledata draw atx0..7. The discrepancy is868 black-native/white-MAME pixels inside that8pixel strip. A later/earlier RAM write within native field0 is not supported by the actual counter. Final-RAM equality alone does not identify renderer/ROM/PROM/reset/epoch behavior.',
      'source_lines':{'MAME_draw':'alpha68k_n.cpp:150-199 (positions, tiledata, sentinel0040, transpen0)',
        'MAME_atomic_screen':'alpha68k_n.cpp:202-209 (background fill followed by three sprite groups)',
        'native_raster_request':'alpha68kn_system.sv:93-97 (master-clock line_start, physical strip port)',
        'native_decode':'alpha68kn_renderer.sv:47-76,153-180 (physical coordinate/ROM/pen decode)',
        'native_RGB_PIPE':'alpha68kn_video_rom.sv:42-52 (clocked CLUT/PROM pipeline)',
        'native_capture':'system_main.cpp:322-340 (native RGB and big-endian word snapshots)'},
      'B16_relation':'The general distinction between atomic MAME screen rendering and physical raster sampling applies. The known Kyros IRQ59/60 boundary proof is not imported as a cause for this profile2 field0 discrepancy.',
      'proven_cause':None,'CPU_clock_or_phase_fix_justified':False,'mask_or_shift_used':False,
      'missing_decisive_observation':['First-field actual strip_data/tile_word/row_pixels/gfx address/data/pen/RGB pipeline plus reset/flip/profile and raster coordinates were not retained by the original111 host.',
        'A fresh bounded matched MAME observer, if needed after181 result, must retain actual reset/first-screen epoch, flip/background, decoded tile0 pixel/pen and source strip words at screen_update; do not rerun1800 to obtain it.'],
      'MAME_raw_terminal_gap_preserved':True,'production_edited':False}
    save(out,record)
    (SCOPE/'frame0_diagnosis.md').write_text('# Super Stingray existing field0 discrepancy\n\n'+record['atomic_vs_raster_assessment']+'\n\n'+record['B16_relation']+'\n\nThe responsible layer remains unknown. No mask, frame shift, clock change or production edit is proposed.\n')
    print(json.dumps({'diagnosis_sha256':H(out),'different_pixels':rgb['different_RGB_pixels'],'bbox':rgb['difference_bbox'],
       'colors':pairs,'native_strip_writes':record['native_accepted_strip_writes_at_frame0'],'retained_MAME_writes':len(accepted)}))

def verify():
    assert not (JOB/'verification.json').exists(),'Preserve the existing terminal qualification.'
    exits={s:json.loads((JOB/(s+'_exit.json')).read_text()) for s in ['build','run']}
    closure=json.loads((SCOPE/'source_closure.json').read_text());cap=JOB/'capture';old=HERE/'coupled_boot111/capture'
    frames=rows(cap/'frames.csv');inputs=rows(cap/'applied_inputs.csv');legal=rows(SCOPE/'gameplay_inputs.csv')
    mcu=rows(cap/'coupled_mcu.csv');before=[r for r in mcu if r['edge']=='before'];commands=[r for r in before if r['command']=='1']
    tmp=(SCOPE/'source/sim/build/wsl_system_build_dir.txt').read_text().strip()
    command=['wsl.exe','-d','Ubuntu','--exec','/bin/bash','-c','cd "$1" && sha256sum -- ./*.sv ./*.v ./*.cpp ./*.h ./*.vlt','sha_scope',tmp]
    actual=subprocess.run(command,capture_output=True,text=True);compiled={}
    if actual.returncode==0:
        for line in actual.stdout.splitlines():sha,name=line.split(None,1);compiled[Path(name.strip()).name]=sha
    expected={Path(p['path']).name:p['combined_sha256'] for p in closure['source_files'] if Path(p['path']).suffix!='.mem'}
    compiled_checks={name:expected.get(name)==sha for name,sha in compiled.items()}
    overlap=[]
    for p in sorted(old.glob('frame_*')):
        q=cap/p.name
        if p.is_file() and q.exists():overlap.append({'name':p.name,'old_sha256':H(p),'new_sha256':H(q),'exact':H(p)==H(q)})
    def ports(r):return tuple(int(r[k]) for k in ['controls','dips','coins_n'])
    checks={'actual_build0':exits['build']['exit_code']==0,'actual_run0':exits['run']['exit_code']==0,
      'same_frozen_ELF_build_run':exits['build']['ELF_sha256']==exits['run']['ELF_sha256'],
      'all75_combined_sources_unchanged':all(H(Path(p['path']))==p['combined_sha256'] for p in closure['source_files']),
      'compiled_real_CPU_graph_hashes_exact':actual.returncode==0 and len(compiled_checks)>60 and all(compiled_checks.values()),
      '181_contiguous_fields':len(frames)==181 and [int(r['frame']) for r in frames]==list(range(181)),
      'actual_input_and_ROM_hashes':all(H(Path(exits['run'][k]['path']))==exits['run'][k]['sha256'] for k in ['input','ROM']),
      'all_applied_actual_ports_match_exact_input':bool(inputs) and all(ports(r)==tuple(int(legal[int(r['frame'])][k]) for k in ['in0','in1','in2']) for r in inputs),
      'actual_coin121_126_and_start161_166':all(int(legal[f]['in2'])==2 for f in range(121,127)) and all(int(legal[f]['in0'])==128 for f in range(161,167)),
      'original111_frame_rows_exact':frames[:111]==rows(old/'frames.csv'),
      'original111_MCU_event_prefix_exact':mcu[:len(rows(old/'coupled_mcu.csv'))]==rows(old/'coupled_mcu.csv'),
      'all_overlapping_old111_raw_arrays_exact':bool(overlap) and all(r['exact'] for r in overlap),
      'all_pixels_no_duplicates_deadlines_overflow':all(int(r['pixels'])==57344 and int(r['duplicates'])==0 and int(r['deadline_misses'])==0 and int(r['row_overflows'])==0 for r in frames)}
    refs=CAN/'sim/captures/sstingry/gameplay';manifest=json.loads((refs/'manifest.json').read_text());comps=[]
    for f in [0,30,90,119,179]:
        item={'frame':f}
        for name,suffix in [('RGB','rgb'),('work','work.bin'),('strip','sprites.bin')]:
            reference_suffix='display.rgb' if name=='RGB' else suffix
            item[name]=comparison(cap/f'frame_{f:06d}.{suffix}',refs/f'frame_{f:06d}.{reference_suffix}',name=='RGB')
        item['RGB_completed_texture_source']={'PNG':entry(refs/f'frame_{f:06d}.png'),
            'RGB':entry(refs/f'frame_{f:06d}.display.rgb'),'orientation':'inverse driver-declared ROT90'}
        comps.append(item)
    checks['all5_required_complete_RGB_work_strip_coordinates_present']=len(comps)==5
    reference=json.loads((SCOPE/'reference_coverage.json').read_text())['references']['gameplay']
    checks['all75_primary_reference_artifact_pins_unchanged']=all(H(refs/r['path'])==r['sha256'] for r in reference['artifacts'])
    primary=[]
    with (refs/'events.csv').open() as f:
        for r in csv.DictReader(f):
            if int(r['frame'])>=181:break
            if r['area'] in ['mcu_command_read','mcu_command_write']:primary.append(r)
    nk=lambda r:(int(r['command_addr']),r['rw']=='1',None if r['rw']=='1' else int(r['dout'])&255)
    mk=lambda r:((int(r['address'])-0x80000)//2,r['area']=='mcu_command_read',None if r['area']=='mcu_command_read' else int(r['data'])&255)
    prefix=0
    for a,b in zip(commands,primary):
        if nk(a)!=mk(b):break
        prefix+=1
    software={'native_commands':len(commands),'primary_commands':len(primary),'ordered_exact_prefix':prefix,
       'full_equal':len(commands)==len(primary)==prefix,'native_first_mismatch':commands[prefix:prefix+1],
       'primary_first_mismatch':primary[prefix:prefix+1],'frame_or_physical_pairing_claimed':False}
    graphics=all(r['RGB']['exact'] for r in comps)
    receipt={'schema':'actual_sstingry_coupled_gameplay181_v1','checks':checks,'protocol_source_pass':all(checks.values()),
      'build_exit':exits['build'],'run_exit':exits['run'],'verifier_sha256':H(Path(__file__)),
      'source_closure_sha256':H(SCOPE/'source_closure.json'),'compiled_graph':tmp,'compiled_hashes':compiled,
      'compiled_hash_checks':compiled_checks,'compiled_hash_exit':actual.returncode,'compiled_hash_stderr':actual.stderr,
      'all5_unshifted_whole_checkpoint_comparisons':comps,'all_old111_array_overlap':overlap,
      'software_commands':software,'actual_shared_write_pulses':[r for r in before if r['shared_write']=='1'],
      'first_frame':frames[0],'last_frame':frames[-1], 'all5_checkpoint_graphics_pass':graphics,
      'graphics_pass':False,'full_attract_pass':False,'gameplay_pass':False,'coin_credit_or_start_semantics_earned':False,
      'MAME_raw_exit_gap_preserved':True,'physical_MCU_pairing_pass':False,'production_edited':False,
      'limits':['Input injection and an181-field replay do not prove playable gameplay, coin credit or successful start.',
        'All5 full graphics/RAM comparisons retain exact own coordinates; no frame shifts, masks or pixel acceptance thresholds.',
        'Original111 source/CPU/MCU/storage proof remains separate; only two pinned sound deltas differ in this combined executable.',
        'Historical MAME raw exit receipts and direct MCU timing taps are absent; finitecomplete manifests and retained source identities are explicit.']}
    save(JOB/'verification.json',receipt)
    (JOB/'verification.md').write_text('# Actual private Super Stingray coupled181\n\n'+
      f"Build/run exited{exits['build']['exit_code']}/{exits['run']['exit_code']}; source/protocol checks={all(checks.values())}. Full checkpoint RGB exact={graphics}.\n\n"+
      '\n'.join(f"Field{r['frame']}: RGB differences={r['RGB']['different_RGB_pixels']}pixels, work exact={r['work']['exact']}, strip exact={r['strip']['exact']}." for r in comps)+
      '\n\nNo whole-game, physical MCU pairing or playable gameplay acceptance follows from this short input replay.\n')
    owned=[HERE/'run_next_coupled181.py',Path(__file__),JOB/'worker.json',JOB/'build_job.json',JOB/'build_exit.json',
      JOB/'run_job.json',JOB/'run_exit.json',JOB/'verification.json',JOB/'verification.md',SCOPE/'frame0_diagnosis.json',SCOPE/'frame0_diagnosis.md']
    save(JOB/'import_manifest.json',{'schema':'private_coupled181_import_v1','entries':[entry(p) for p in owned],
      'large_evidence_references':[entry(p) for p in [JOB/'build.log',JOB/'run.log']+[p for p in sorted(cap.iterdir()) if p.is_file()]],
      'frozen_scope_manifest':entry(SCOPE/'import_manifest.json'),'no_replay_authorization':True})
    print(json.dumps({'checks':checks,'checkpoint_differences':[{'frame':r['frame'],'RGB_pixels':r['RGB']['different_RGB_pixels'],'work':r['work']['different_bytes'],'strip':r['strip']['different_bytes']} for r in comps],
      'software':software,'last_frame':frames[-1],'verification_sha256':H(JOB/'verification.json'),'manifest_sha256':H(JOB/'import_manifest.json')}))

def main():
    action=sys.argv[1]
    if action=='launch-wait':
        assert not (JOB/'verification_waiter.json').exists(),'Observe existing waiter; no relaunch.'
        diagnose_zero()
        with (JOB/'verification_waiter.log').open('w') as f:
            p=subprocess.Popen([sys.executable,'-X','utf8',str(Path(__file__)),'wait'],stdout=f,stderr=subprocess.STDOUT,
               creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        save(JOB/'verification_waiter.json',{'pid':p.pid,'helper_sha256':H(Path(__file__)),'poll_seconds':45,'started':time.time()})
        print(json.dumps({'waiter_pid':p.pid}));return
    if action=='wait':
        while not (JOB/'run_exit.json').exists():time.sleep(45)
    assert action in ['wait','verify']
    try:
        verify();save(JOB/'verification_exit.json',{'exit_code':0,'helper_sha256':H(Path(__file__)),'finished':time.time()})
    except Exception as e:
        save(JOB/'verification_exit.json',{'exit_code':1,'error':repr(e),'helper_sha256':H(Path(__file__)),'finished':time.time()});raise

if __name__=='__main__':main()
