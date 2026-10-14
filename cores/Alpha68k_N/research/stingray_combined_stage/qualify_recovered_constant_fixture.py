"""Close the existing renderer diagnostic without changing game sources or claims."""
from pathlib import Path
import hashlib, json, time

HERE=Path(__file__).resolve().parent; SCOPE=HERE/'next_coupled_scope_v2'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def load(p):return json.loads(p.read_text())
def compare(a,b):
    av,bv=a.read_bytes(),b.read_bytes();assert len(av)==len(bv)==172032
    pixels=[i//3 for i in range(0,len(av),3) if av[i:i+3]!=bv[i:i+3]]
    return {'a':pin(a),'b':pin(b),'exact':not pixels,'different_pixels':len(pixels),
      'bbox':[min(i%256 for i in pixels),min(i//256 for i in pixels),max(i%256 for i in pixels),max(i//256 for i in pixels)] if pixels else None}
def main():
    job=SCOPE/'frame0_constant_fixture_recovery_v2';end=time.time()+600
    while not (job/'run_exit.json').exists():
      if (job/'build_exit.json').exists() and load(job/'build_exit.json')['exit_code']!=0:break
      if time.time()>end:raise RuntimeError('Existing diagnostic still lacks terminal receipt; no rerun.')
      time.sleep(5)
    assert not (job/'qualification.json').exists()
    pins=load(job/'pins.json');build=load(job/'build_exit.json')
    assert all(H(Path(p['path']))==p['actual_fixture_sha256'] for p in pins['source_files'])
    terminal=load(job/'run_exit.json') if (job/'run_exit.json').exists() else None
    result={'schema':'actual_sstingry_first_field_constant_RAM_diagnostic_v1','build':build,'run':terminal,
      'all12_source_pins_exact':True,'pins':pin(job/'pins.json'),'no_CPU_game_acceptance':True,
      'cause_not_yet_selected':True,'helper':pin(Path(__file__))}
    if terminal:
      lines=(job/'run.log').read_text().splitlines()
      result['native_fixture_result']=[json.loads(x) for x in lines if x.startswith('{')][-1]
      rgb=job/'capture/actual.rgb';expected=job/'capture/expected.rgb';oracle=Path(pins['MAME_RGB']['path'])
      result['actual_vs_transcription']=compare(rgb,expected)
      result['actual_vs_MAME']=compare(rgb,oracle)
      result['transcription_vs_MAME']=compare(expected,oracle)
      original=HERE/'coupled_boot111/capture/frame_000000.rgb'
      result['original_native_first_field_vs_steady_fixture']=compare(original,rgb)
    q=job/'qualification.json';q.write_text(json.dumps(result,indent=2)+'\n')
    files=[pin(p) for p in job.glob('*.json')]+[pin(job/n) for n in ['worker.log','build.log','run.log'] if (job/n).exists()]
    files += [pin(HERE/n) for n in ['run_frame0_constant_fixture_recovery_v2.py','recover_interrupted_fixture.py','qualify_recovered_constant_fixture.py']]
    files += [pin(SCOPE/'frame0_constant_fixture/interruption_recovery.json')]
    manifest={'schema':'actual_renderer_first_field_diagnostic_import_v1','files':files,
      'large_recovery':[pin(job/'capture/actual.rgb'),pin(job/'capture/expected.rgb')] if terminal else [],
      'all_source_files':pins['source_files'],'diagnostic_only':True}
    m=job/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
    summary={k:v for k,v in result.items() if k not in ['build','run','helper','pins']}
    summary['terminal_exits']={'build':build['exit_code'],'run':terminal['exit_code'] if terminal else None}
    summary['manifest']=pin(m)
    print(json.dumps(summary))
    v=load(SCOPE/'recovered_181/result.json')
    print(json.dumps({'181_checkpoints':[{k:({a:b for a,b in val.items() if a not in ['native','MAME']} if isinstance(val,dict) else val) for k,val in row.items()} for row in v['whole_checkpoint_comparisons']]}))
if __name__=='__main__':main()
