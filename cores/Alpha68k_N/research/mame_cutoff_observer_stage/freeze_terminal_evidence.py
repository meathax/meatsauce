"""Freeze successful finite observer evidence; no B16 or hardware promotion."""
from pathlib import Path
import hashlib,json,shutil
HERE=Path(__file__).resolve().parent
TERMINAL=HERE/'terminal'
TERMINAL.mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return dict(path=str(p),sha256=sha(p),bytes=p.stat().st_size)
q=json.loads((HERE/'run61_qualification.json').read_text())
if not all(q['checks'].values()):raise RuntimeError('Finite qualifier failed')
for path in [HERE/'build_v5/make_minimal_exit.json',HERE/'build_v5/private_build_exit.json',HERE/'build_v5/run61_worker_exit.json',HERE/'run61_exit.json',HERE/'run61_check_exit.json']:
    if json.loads(path.read_text())['exit_code']!=0:raise RuntimeError('Missing actual successful terminal: '+str(path))
raw=Path(q['cutoff_log']['path'])
if sha(raw)!=q['cutoff_log']['sha256']:raise RuntimeError('Cutoff raw log changed')
shutil.copy2(raw,TERMINAL/'raw_cutoff.log')
windows=[]
for w in q['windows']:
    assertion=w['assertions'][0]
    before=next(r for r in w['records'] if r['event']=='cutoff_before' and r['sequence']>assertion['sequence'])
    after=next(r for r in w['records'] if r['event']=='cutoff_after' and r['sequence']==before['sequence']+1)
    windows.append(dict(bounds=w['window'],records=len(w['records']),pairs=w['before_count'],assertion=assertion,first_following_cutoff_before=before,first_following_cutoff_after=after,input_to_following_cutoff_local_ticks=before['local_ticks']-assertion['local_ticks']))
summary=dict(checks=q['checks'],csv_files_exact=len(q['csv_comparisons']),whole_raw_arrays_exact=len(q['whole_array_comparisons']),stream=q['cutoff_stream_summary'],windows=windows,raw_log=pin(raw),local_machine_times_retained_separately=True,B16_closed=False,physical_cause_proven=False,CPU_or_clock_correction_justified=False,limits='Finite MAME observer qualification only. No timing normalization, PC-based alignment, graphics masking or hardware promotion.')
(TERMINAL/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
names=['freeze_terminal_evidence.py','run_and_verify61.py','run61_job.json','run61_exit.json','run61_check_exit.json','run61_qualification.json','run61.log','build_v5/shell_probe.json','build_v5/make_minimal_exit.json','build_v5/private_build_exit.json','build_v5/run61_worker_exit.json','build_v5/run61_worker.log','build_v5/build_status.json','terminal/raw_cutoff.log','terminal/summary.json']
entries=[]
for n in names:
    entry=pin(HERE/n);entry['relative_path']=n;entries.append(entry)
capture=raw.parent
recovery=[pin(p) for p in sorted(capture.rglob('*')) if p.is_file()]
recovery.extend(pin(p) for p in [HERE/'build_v5/make_minimal.log',HERE/'build_v3/private_source_manifest.json',Path(json.loads((HERE/'build_v5/private_build_exit.json').read_text())['executable']['path'])])
manifest=dict(files=entries,recovery_only=recovery,finite_observer_qualified=True,B16_closed=False,physical_cause_proven=False,no_new_replay_or_hardware_change=True)
out=HERE/'terminal_import_manifest.json'
if out.exists():raise RuntimeError('Terminal manifest already frozen')
out.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(manifest=pin(out),file_count=len(entries),recovery_count=len(recovery),windows=[dict(pairs=w['pairs'],assertion=w['assertion']['local_ticks'],first_following_cutoff=w['first_following_cutoff_before']['local_ticks']) for w in windows])))
