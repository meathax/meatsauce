"""One authorized private-binary61 capture; verify before interpretation."""
from pathlib import Path
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import traceback
import argparse

HERE=Path(__file__).resolve().parent
OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
REFERENCE=OLD/'sim/captures/kyros/mame_cutoff_observer61'
CAPTURE=OLD/'sim/captures/kyros/mame_ordinary_cutoff61'
arguments=argparse.ArgumentParser()
arguments.add_argument('--build-result',type=Path,default=HERE.parent/'build_v5/private_build_exit.json')
build_result=arguments.parse_args().build_result

def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def write(name,obj):
    (HERE/name).write_text(json.dumps(obj,indent=2)+'\n')

def rows(p):
    with p.open(newline='') as f:return list(csv.DictReader(f))

try:
    if CAPTURE.exists():raise RuntimeError('Capture already exists; refusing duplicate replay')
    build=json.loads(build_result.read_text())
    if build['exit_code']!=0:raise RuntimeError('Actual private build is not successful')
    exe=Path(build['executable']['path'])
    if sha(exe)!=build['executable']['sha256']:raise RuntimeError('Private executable changed')
    manifest=Path(build.get('source_manifest_path',HERE.parent/'build_v3/private_source_manifest.json'))
    if sha(manifest)!=build['source_manifest_sha256']:raise RuntimeError('Frozen source manifest changed')
    source=json.loads(manifest.read_text())
    source_root=Path(source['root'])
    changed=[e['relative_path'] for e in source['files'] if not (source_root/e['relative_path']).is_file() or sha(source_root/e['relative_path'])!=e['sha256']]
    if changed:raise RuntimeError('Frozen source changed: '+repr(changed[:10]))
    job=json.loads((OLD/'research/irq_sampling_edge_mame61_job.json').read_text())
    ref_recorder=REFERENCE/'loaded_recorder.lua'
    if sha(ref_recorder)!=job['observer_sha256']:raise RuntimeError('Qualified reference recorder changed')
    CAPTURE.mkdir(parents=True)
    for n in ['cfg','nvram','states']:(CAPTURE/n).mkdir()
    original_cfg=OLD/'sim/captures/kyros/warm_reset960_refv2/cfg'
    cfgpins=[]
    for p in sorted(original_cfg.glob('*.cfg')):
        shutil.copy2(p,CAPTURE/'cfg'/p.name)
        cfgpins.append({'source':str(p),'sha256':sha(p),'destination':str(CAPTURE/'cfg'/p.name)})
    recorder=CAPTURE/'loaded_recorder.lua'
    original_lua=ref_recorder.read_text()
    added_lua='\n-- BEGIN bounded read-only ordinary fetch observer\nlocal ordinary_rom = open("ordinary_rom.csv")\nordinary_rom:write("frame,machine_ticks,address,data,mask,pc,ipc,ir,ird,irc,pending,next,inst_state,inst_substate\\n")\nhandles[#handles+1] = space:install_read_tap(0x850,0x85f,"alpha_ordinary_rom",function(a,d,m)\n    local t=machine.time:as_ticks(48000000)\n    if (t>=47848665 and t<=47849965) or (t>=47999200 and t<=48000500) then\n        ordinary_rom:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\\n",frame,t,a,d,m,pc(main),main.state["CURPC"].value,main.state["IR"].value,main.state["IRQ_IRD"].value,main.state["IRQ_IRC"].value,main.state["IRQ_PENDING_STATE"].value,main.state["IRQ_NEXT_STATE"].value,main.state["IRQ_INST_STATE"].value,main.state["IRQ_INST_SUBSTATE"].value))\n        ordinary_rom:flush()\n    end\nend)\n-- END bounded read-only ordinary fetch observer\n'
    anchor="local function set_input(tag, mask, active)"
    assert original_lua.count(anchor)==1
    recorder.write_text(original_lua.replace(anchor,added_lua+anchor))
    command=list(job['command'])
    command[0]=str(exe)
    overrides={'-autoboot_script':recorder,'-snapshot_directory':CAPTURE,'-cfg_directory':CAPTURE/'cfg','-nvram_directory':CAPTURE/'nvram','-state_directory':CAPTURE/'states','-wavwrite':CAPTURE/'audio.wav'}
    for flag,path in overrides.items():command[command.index(flag)+1]=str(path)
    command.append('-log')
    env=os.environ.copy()
    env.update({'ALPHA_CAPTURE_DIR':str(CAPTURE),'ALPHA_CAPTURE_MODE':'warm-reset','ALPHA_CAPTURE_FRAMES':'61'})
    pin={'worker_pid':os.getpid(),'command':command,'cwd':str(CAPTURE),'executable':build['executable'],'source_manifest_sha256':sha(manifest),'frozen_source_files':len(source['files']),'all_frozen_files_unchanged':True,'reference_job_sha256':sha(OLD/'research/irq_sampling_edge_mame61_job.json'),'reference_recorder_sha256':sha(ref_recorder),'cloned_recorder_sha256':sha(recorder),'cfg_seed_pins':cfgpins,'environment':{k:env[k] for k in ['ALPHA_CAPTURE_DIR','ALPHA_CAPTURE_MODE','ALPHA_CAPTURE_FRAMES']},'original_input_reference_sha256':job['input_reference_sha256'],'old_executable_identity_assigned_to_new_binary':False}
    with (HERE/'run61.log').open('wb') as log:
        process=subprocess.Popen(command,cwd=CAPTURE,env=env,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
        pin['mame_pid']=process.pid
        write('run61_job.json',pin)
        code=process.wait()
    write('run61_exit.json',{'exit_code':code,'mame_pid':process.pid,'executable':build['executable'],'log_sha256':sha(HERE/'run61.log'),'completed':time.time()})
    expected_csvs=sorted(p.name for p in REFERENCE.glob('*.csv'))
    comparisons={}
    for name in expected_csvs:
        a=REFERENCE/name;b=CAPTURE/name
        if not b.exists():
            comparisons[name]={'exact':False,'missing':True};continue
        ar=rows(a);br=rows(b)
        first=next((i for i,(x,y) in enumerate(zip(ar,br)) if x!=y),None)
        comparisons[name]={'exact':ar==br,'reference_rows':len(ar),'new_rows':len(br),'first_different_row':first,'reference_sha256':sha(a),'new_sha256':sha(b)}
        if first is not None:
            comparisons[name]['first_reference']=ar[first]
            comparisons[name]['first_new']=br[first]
    # Every retained whole raw snapshot array must compare without transforms.
    arrays={}
    for p in sorted(REFERENCE.glob('frame_*')):
        if not p.is_file() or p.suffix.lower() not in {'.rgb','.bin'}:continue
        q=CAPTURE/p.name
        arrays[p.name]={'exact':q.exists() and p.read_bytes()==q.read_bytes(),'reference_sha256':sha(p),'new_sha256':sha(q) if q.exists() else None,'bytes':p.stat().st_size}
    log_text=(HERE/'run61.log').read_text(errors='replace')
    cutoff_log=CAPTURE/'error.log'
    # Windows MAME -log ordinarily uses error.log in the process working dir.
    records=[]
    record_count=0
    malformed_count=0
    sequence_gaps=[]
    previous_sequence=None
    cutoff_bounds=[[47847465,47851465],[47998000,48002000]]
    if cutoff_log.exists():
        with cutoff_log.open(errors='replace') as stream:
            for line in stream:
                start=line.find('IRQ_CUTOFF,')
                if start<0:continue
                fields=line[start:].strip().split(',')
                if len(fields)!=16:
                    malformed_count+=1
                    continue
                names=['sequence','event','local_ticks','machine_ticks','total_cycles','icount','pc','ipc','ir','ird','irc','sr','level','pending','next']
                rec=dict(zip(names,fields[1:]))
                for name in names:
                    if name!='event':rec[name]=int(rec[name])
                record_count+=1
                if previous_sequence is not None and rec['sequence']!=previous_sequence+1:
                    if len(sequence_gaps)<8:sequence_gaps.append({'previous':previous_sequence,'next':rec['sequence']})
                previous_sequence=rec['sequence']
                if any(lo<=rec['local_ticks']<=hi for lo,hi in cutoff_bounds):records.append(rec)
    windows=[]
    for lo,hi in cutoff_bounds:
        subset=[r for r in records if lo<=r['local_ticks']<=hi]
        assertions=[r for r in subset if r['event']=='input_applied' and r['level']>0 and r['pending']>0]
        before=[r for r in subset if r['event']=='cutoff_before']
        after=[r for r in subset if r['event']=='cutoff_after']
        windows.append({'window':[lo,hi],'records':subset,'assertions':assertions,'before_count':len(before),'after_count':len(after),'nonvacuous':bool(assertions and before and after),'pair_sequences_valid':all(b['sequence']+1==a['sequence'] for b,a in zip(before,after)) and len(before)==len(after)})
    state_rows=rows(CAPTURE/'frame_states.csv') if (CAPTURE/'frame_states.csv').exists() else []
    checks={'actual_private_build0':build['exit_code']==0,'actual_new_mame_terminal0':code==0,'no_lua_failure':not any(s in log_text.lower() for s in ['lua error','error running','stack traceback']),'cloned_qualified_recorder_exact':recorder.read_text().replace(added_lua,'')==original_lua,'all_frozen_source_files_unchanged_before_run':not changed,'all61_contiguous':len(state_rows)==61 and [int(r['frame']) for r in state_rows]==list(range(61)),'all_reference_csvs_exact':bool(comparisons) and all(v['exact'] for v in comparisons.values()),'all_retained_whole_raw_arrays_exact':bool(arrays) and all(v['exact'] for v in arrays.values()),'actual_cutoff_records_present':record_count>0,'all_cutoff_records_well_formed_and_sequences_contiguous':malformed_count==0 and not sequence_gaps,'both_original_irq_windows_nonvacuous':all(v['nonvacuous'] for v in windows),'cutoff_before_after_pair_sequences_valid':all(v['pair_sequences_valid'] for v in windows)}
    result={'checks':checks,'finite_observer_acceptance_pass':all(checks.values()),'csv_comparisons':comparisons,'whole_array_comparisons':arrays,'cutoff_log':{'path':str(cutoff_log),'sha256':sha(cutoff_log) if cutoff_log.exists() else None},'cutoff_records':records,'windows':windows,'runtime_mame_cutoff_observed':bool(records),'physical_cause_proven':False,'B16_closed':False,'CPU_or_clock_correction_justified':False,'limits':'Actual local-time and scheduler machine-time records remain distinct. Full reference parity required before semantic comparison; no physical-cause conclusion from correlation.'}
    result['cutoff_stream_summary']={'complete_raw_record_count':record_count,'malformed_count':malformed_count,'first_sequence_gaps':sequence_gaps,'last_sequence':previous_sequence,'json_records_scope':'Only both declared cutoff windows; complete uncapped raw log retained and SHA pinned.'}
    write('run61_qualification.json',result)
    check_code=0 if all(checks.values()) else 1
    write('run61_check_exit.json',{'exit_code':check_code,'qualification_sha256':sha(HERE/'run61_qualification.json')})
    print(json.dumps({'checks':checks,'check_exit':check_code,'record_count':record_count,'window_records':len(records)}))
    raise SystemExit(check_code)
except Exception as exc:
    write('run61_worker_failure.json',{'error':str(exc),'traceback':traceback.format_exc(),'physical_cause_proven':False,'B16_closed':False})
    raise
