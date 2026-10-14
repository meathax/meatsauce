"""Retain compact authentic recovery evidence; no game acceptance promotion."""
from pathlib import Path
import hashlib, json, subprocess

HERE = Path(__file__).resolve().parent
SCOPE = HERE / 'next_coupled_scope_v2'
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p): return {'path':str(p), 'sha256':H(p), 'bytes':p.stat().st_size}
def load(p): return json.loads(p.read_text())
def main():
    job=SCOPE/'coupled181'; v=load(job/'verification.json')
    out=SCOPE/'recovered_181'; out.mkdir(exist_ok=True)
    assert not (out/'result.json').exists(), 'Immutable result already exists; observe it.'
    receipts={name:load(job/name) for name in ['build_exit.json','run_exit.json','verification_exit.json']}
    assert all(x['exit_code']==0 for x in receipts.values())
    assert all(x is True for x in v['checks'].values())
    checkpoints=[]
    for row in v['all5_unshifted_whole_checkpoint_comparisons']:
        checkpoints.append(row)
    result={'schema':'recovered_real_coupled181_terminal_v1',
      'checks':v['checks'],'protocol_source_pass':v['protocol_source_pass'],
      'receipts':receipts, 'whole_checkpoint_comparisons':checkpoints,
      'verification_pin':pin(job/'verification.json'),
      'original_import_manifest':pin(job/'import_manifest.json'),
      'complete_graphics_gate':False,'complete_audio_gate':False,'whole_game_gate':False,
      'limits':'181 fields and finite checkpoint comparisons; no timing, physical or full-game acceptance.',
      'helper':pin(Path(__file__))}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    names=['build_job.json','build_exit.json','run_job.json','run_exit.json','verification_waiter.json','verification_exit.json','verification.json','import_manifest.json']
    manifest={'schema':'append_only_real_coupled181_recovery_v1',
      'files':[pin(job/n) for n in names]+[pin(out/'result.json'),pin(Path(__file__))],
      'recovery_manifest':pin(job/'import_manifest.json'),'no_acceptance_promotion':True}
    (out/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'181':{'checks':len(v['checks']), 'receipts':{k:x['exit_code'] for k,x in receipts.items()},
      'manifest':pin(out/'import_manifest.json'),'checkpoint_keys':[list(x) for x in checkpoints]}}))
    fixture=SCOPE/'frame0_constant_fixture'
    print(json.dumps({'fixture_terminal':{n:load(fixture/n) for n in ['build_exit.json','run_exit.json'] if (fixture/n).exists()},
       'fixture_log':(fixture/'run.log').read_text()[-3000:] if (fixture/'run.log').exists() else 'not present'}))
    print(subprocess.run(['wsl.exe','-d','Ubuntu','--exec','/bin/ps','-eo','pid,ppid,etime,comm,args'],capture_output=True,text=True).stdout.split('alpha68kn-render')[-1][-1000:])
if __name__=='__main__':main()
