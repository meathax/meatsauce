import pathlib,json,hashlib,subprocess
out=pathlib.Path(__file__).parent
base=out.parent/'joined_rom_inference_v2'
core=pathlib.Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
native=load(base/'map_qualification.json')['mapped_source_pins_160']
origin=load(base/'diagnostic_prepared.json')['source_pins_161']
rows=[]
for closure,records in [('native160',native),('origin161',origin)]:
    for e in records:
        p=pathlib.Path(e['path']);assert sha(p)==e['sha256']
        c=core/pathlib.Path(e['relative'])
        row={'closure':closure,'relative':e['relative'],'fitted_path':str(p),'fitted_sha256':e['sha256'],'canonical_path':str(c),'canonical_exists':c.exists()}
        if c.exists():
            before=p.read_bytes();after=c.read_bytes();row['canonical_sha256']=sha(c)
            row['exact']=before==after
            row['crlf_to_lf_only']=before.replace(b'\r\n',b'\n')==after and before!=after
            row['canonical_commit_blob_sha256']=None
        rows.append(row)
        if not row.get('exact'):print('DIFFERENCE',json.dumps(row))
repo=core.parent.parent
gitdir=repo/'.git'
head=(gitdir/'HEAD').read_text().strip()
if head.startswith('ref: '):
    ref=head[5:];refpath=gitdir/ref
    if refpath.exists():head=refpath.read_text().strip()
    else:head=next(l.split()[0] for l in (gitdir/'packed-refs').read_text().splitlines() if l.endswith(' '+ref))
assert head.startswith('6caf'),head
receipt=out.parent/'functional_integration_v4_20261011/root_commit_v4.json'
commit_receipt=load(receipt)
assert head in json.dumps(commit_receipt),head
print('HEAD_DIRECT_READ',head,'COMMIT_RECEIPT_KEYS',list(commit_receipt))
release=out.parent/'functional_integration_v4_20261011/released_plan.json'
assert sha(release)=='bff403ad07e41a6e3fbd444b0d1aa3922256a4d412b18dcda9d3234f5bb03a2a'
plan=load(release)
print('RELEASE_KEYS',list(plan))
print('ROWS',len(rows),'EXACT',sum(r.get('exact',False) for r in rows),'NEWLINE',sum(r.get('crlf_to_lf_only',False) for r in rows))
result={'canonical_head':head,'head_binding':'Direct HEAD/ref read and existing root commit receipt; no current Git-status command claim','canonical_commit_receipt':{'path':str(receipt),'sha256':sha(receipt),'data':commit_receipt},'canonical_core':str(core),'rows':rows,'released_plan':{'path':str(release),'sha256':sha(release)}}
p=out/'canonical_epoch_probe.json';assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print('PROBE',p,sha(p))
