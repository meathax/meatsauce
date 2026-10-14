from pathlib import Path
import hashlib,json,difflib
stage=Path(__file__).parent
source=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
before=source.read_text(encoding='utf-8')
assert hashlib.sha256(source.read_bytes()).hexdigest()=='a9ee073877dcb63434ab9282ce97b87cbdcbfe93ced24462bf198fccc85dcf6d'
old="""    project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
    output=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
    if canonical(args[2])!=canonical(project):return False
    if args[3]!='Alpha68k_N' or canonical(args[4])!=canonical(output):return False
"""
new="""    check_root=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/'
    project_outputs={
        canonical(check_root+'case2_full_map/Alpha68k_N'):canonical(check_root+'case2_fit_sta/all-corners'),
        canonical(check_root+'case2_standard_fit/Alpha68k_N'):canonical(check_root+'case2_standard_fit_evidence/all-corners'),
    }
    project=canonical(args[2])
    output=project_outputs.get(project)
    if output is None or canonical(args[4])!=output or args[3]!='Alpha68k_N':return False
    # The independent standard-fit diagnostic requires the detailed collector.
    if project==canonical(check_root+'case2_standard_fit/Alpha68k_N') and expected_hash!='ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab':return False
"""
assert before.count(old)==1
after=before.replace(old,new,1)
stage.joinpath('baseline.py').write_bytes(source.read_bytes())
stage.joinpath('candidate.py').write_text(after,encoding='utf-8',newline='\n')
stage.joinpath('candidate.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='baseline.py',tofile='candidate.py')),encoding='utf-8')
prior=stage.parent/'queue_guard_sta_detail'
for name in ['verify_original155.py','verify_collector.py']:stage.joinpath(name).write_bytes(prior.joinpath(name).read_bytes())
previous=prior.joinpath('verify_detail.py').read_text()
previous=previous.replace("        assert old['hookSpecificOutput']['permissionDecision']=='deny'\n",'        assert old==new\n')
stage.joinpath('verify_original204.py').write_text(previous,encoding='utf-8')
meta={'baseline_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256(stage.joinpath('candidate.py').read_bytes()).hexdigest(),'collector_sha256':'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a','detail_collector_sha256':'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab','deployment':False}
stage.joinpath('source_pins.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
print(json.dumps(meta))
