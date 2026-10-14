"""Explicit reviewed guard-only deployment. Never starts an FPGA tool or queue job."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, os

stage=Path(__file__).resolve().parent
manifest=json.loads((stage/'manifest.json').read_text(encoding='utf-8'))
receipt=json.loads((stage/'test_receipt.json').read_text(encoding='utf-8'))
target=Path(manifest['original_path'])
backup=target.with_name('shared_quartus_queue_hook.backup-20261010-irq-policy-'+manifest.get('deploy_from_sha256',manifest['original_sha256'])[:12]+'.py')
temporary=target.with_name('shared_quartus_queue_hook.reviewed.tmp')
def sha(data):return hashlib.sha256(data).hexdigest()
original=target.read_bytes(); candidate=(stage/'shared_quartus_queue_hook.py').read_bytes()
assert sha(original)==manifest.get('deploy_from_sha256',manifest['original_sha256'])
assert sha(candidate)==manifest['candidate_sha256']==receipt['candidate_sha256']
assert receipt['status']=='pass' and receipt['cases']>=69
compile(candidate,str(target),'exec')
assert not backup.exists() and not temporary.exists()
protected=[Path(r'C:\Users\meath\.codex\hooks.json'),Path(r'C:\Users\meath\.claude\settings.json'),target.with_name('quartus_worker.ps1'),Path(r'C:\Users\meath\QuartusFast\quartusfast.py')]
protected.append(target.with_name('shared_quartus_queue.ps1'))
pins={str(p):sha(p.read_bytes()) for p in protected}
backup.write_bytes(original)
assert sha(backup.read_bytes())==sha(original)
try:
    temporary.write_bytes(candidate)
    assert sha(temporary.read_bytes())==manifest['candidate_sha256']
    os.replace(temporary,target)
    assert sha(target.read_bytes())==manifest['candidate_sha256']
    assert all(sha(Path(p).read_bytes())==digest for p,digest in pins.items())
except Exception:
    if target.exists() and sha(target.read_bytes())==manifest['candidate_sha256']:
        target.write_bytes(original)
    raise
result={'status':'deployed','utc':datetime.now(timezone.utc).isoformat(),'target':str(target),'backup':str(backup),'original_sha256':sha(original),'deployed_sha256':sha(target.read_bytes()),'classification_cases':receipt['cases'],'protected_unchanged':pins,'limits':'Only shared PreToolUse classifier changed; no hook configuration, controller, queue worker, production source, lease state, simulation or FPGA tool launch. Ordinary permission review remains active.'}
(stage/'deployment_receipt.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:result[k] for k in ['status','target','backup','original_sha256','deployed_sha256','classification_cases']}))
