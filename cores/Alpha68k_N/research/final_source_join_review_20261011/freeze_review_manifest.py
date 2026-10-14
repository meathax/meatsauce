from pathlib import Path
import hashlib,json
root=Path(__file__).parent
target=root/'import_manifest.json'
assert not target.exists(),'Immutable output exists'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
files=[{'path':str(path),'bytes':path.stat().st_size,'sha256':sha(path)} for path in sorted(root.iterdir()) if path.is_file() and path!=target]
receipt={'scope':'Independent read-only source join review; v1 P1 preserved and resolved in v2. No builds, replays, timing or hardware qualification.','approved_for_bounded_merge':True,'actual_review_exit':0,'source_manifest_sha256':'029088a70ad03611730d0ad0b9f6c4db9ad53a867859ed5f8ca4f3b29f82427b','files':files}
target.write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'path':str(target),'sha256':sha(target),'files':len(files),'approved_for_bounded_merge':True}))
