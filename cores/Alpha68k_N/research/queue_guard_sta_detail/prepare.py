from pathlib import Path
import hashlib,json,difflib
stage=Path(__file__).parent
source=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
before=source.read_text(encoding='utf-8')
assert hashlib.sha256(source.read_bytes()).hexdigest()=='294f6b5d02bd99f316b50a880a2e9376afcbcaeacc733732442d1c9e734946d8'
old="    collector=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners.tcl'\n"
new="""    collector_root=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/'
    approved_collectors={
        canonical(collector_root+'all-corners.tcl'):'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a',
        canonical(collector_root+'all-corners-detail.tcl'):'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab',
    }
    collector=args[1]
    expected_hash=approved_collectors.get(canonical(collector))
    if expected_hash is None:return False
"""
assert before.count(old)==1
after=before.replace(old,new,1)
old='    if canonical(args[1])!=canonical(collector) or canonical(args[2])!=canonical(project):return False\n'
assert after.count(old)==1
after=after.replace(old,'    if canonical(args[2])!=canonical(project):return False\n',1)
old="hashlib.sha256(content).hexdigest()=='3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a'"
assert after.count(old)==1
after=after.replace(old,'hashlib.sha256(content).hexdigest()==expected_hash',1)
stage.joinpath('baseline.py').write_bytes(source.read_bytes())
stage.joinpath('candidate.py').write_text(after,encoding='utf-8',newline='\n')
stage.joinpath('candidate.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='baseline.py',tofile='candidate.py')),encoding='utf-8')
prior=stage.parent/'queue_guard_sta_collector'
for name in ['verify_original155.py','verify_collector.py']:stage.joinpath(name).write_bytes(prior.joinpath(name).read_bytes())
meta={'baseline_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256(stage.joinpath('candidate.py').read_bytes()).hexdigest(),'collector_sha256':'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a','detail_collector_sha256':'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab','deployment':False}
stage.joinpath('source_pins.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
print(json.dumps(meta))
