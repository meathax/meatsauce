from pathlib import Path
import hashlib,json
stage=Path(__file__).resolve().parent
receipt=json.loads((stage/'deployment_receipt.json').read_text())
def sha(data):return hashlib.sha256(data).hexdigest()
checks={p:sha(Path(p).read_bytes())==digest for p,digest in receipt['protected_unchanged'].items()}
assert all(checks.values())
def strings(obj):
    if isinstance(obj,str):yield obj
    elif isinstance(obj,dict):
        for value in obj.values():yield from strings(value)
    elif isinstance(obj,list):
        for value in obj:yield from strings(value)
target=receipt['target'].lower().replace('/','\\')
matches={}
for name in ['codex','claude']:
    path=Path(r'C:\Users\meath')/('.codex/hooks.json' if name=='codex' else '.claude/settings.json')
    data=json.loads(path.read_text(encoding='utf-8'))
    matches[name]=[value for value in strings(data) if target in value.lower().replace('/','\\')]
    assert len(matches[name])==1
queue=Path(receipt['target']).with_name('shared_quartus_queue.ps1')
result={'status':'pass','live_sha256':sha(Path(receipt['target']).read_bytes()),'backup_sha256':sha(Path(receipt['backup']).read_bytes()),'protected_hash_checks':checks,'hook_shared_target_matches':matches,'queue_library_path':str(queue),'queue_library_sha256':sha(queue.read_bytes()),'actual_deployment':{'exit_code':0,'chunk_id':'93d341'},'actual_deployed_classification':{'exit_code':0,'chunk_id':'c00291','cases':69},'actual_readonly_smoke':{'status':'pending_parent_exact_original_smoke','initial8fe_smaller_smoke_exit_code':0,'initial8fe_smaller_smoke_chunk_id':'f735fe'},'quartus_job_preserved':{'session_id':96534,'status':'map_live_no_terminal'},'limits':'Second deployment records actual before/after queue-library identity in protected hashes. Independent reviewer current snapshot matches; first deployment did not record a queue-library before hash and no stronger claim is made.'}
assert result['live_sha256']==receipt['deployed_sha256'] and result['backup_sha256']==receipt['original_sha256']
(stage/'deployment_verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':'pass','live_sha256':result['live_sha256'],'shared_target_matches':{k:len(v) for k,v in matches.items()},'queue_library_sha256':result['queue_library_sha256'],'protected_hash_checks':checks}))
files=[p for p in stage.iterdir() if p.is_file() and p.suffix in {'.py','.json','.patch'} and p.name!='import_manifest.json']
manifest={'status':'verified_stage','root':str(stage),'deployed_sha256':result['live_sha256'],'original_global_backup':r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.backup-20261010-irq-policy.py','original_global_sha256':'1046f079e2a740bc9ea8301922586cc5dc16176f0e623883550e9861a69378bb','predecessor_backup':receipt['backup'],'files':[{'name':p.name,'sha256':sha(p.read_bytes())} for p in sorted(files)],'scope':'Guard repair evidence/code only; no canonical core/controller/queue-worker/RTL changes, no assembly or duplicate launch. Root owns canonical imports.'}
(stage/'import_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'import_files':len(files),'manifest_sha256':sha((stage/'import_manifest.json').read_bytes())}))
