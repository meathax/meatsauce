from pathlib import Path
import hashlib, json, difflib

stage=Path(__file__).parent
source=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
before=source.read_text(encoding='utf-8')
assert hashlib.sha256(source.read_bytes()).hexdigest()=='afcf3db289db892de176c233b411a267d1c687012e1334988a83ffd8b3efbf04'
helper='''def reviewed_sta_collector(exe: str, args: list[str]) -> bool:
    """One reviewed, hash-pinned report-only collector on this fitted database.

    Never delegate arbitrary Tcl. Exact project/output arguments also keep report
    writes inside the already reviewed isolated check workspace. No tool launches
    or queue/RBF authority are granted by this predicate.
    """
    if canonical(exe)!=canonical(r'D:/q17/quartus/bin64/quartus_sta.exe'):return False
    if len(args)!=5 or args[0]!='-t':return False
    collector=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners.tcl'
    project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
    output=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
    if canonical(args[1])!=canonical(collector) or canonical(args[2])!=canonical(project):return False
    if args[3]!='Alpha68k_N' or canonical(args[4])!=canonical(output):return False
    try:
        with open(collector,'rb') as evidence:content=evidence.read(65537)
        return len(content)<=65536 and hashlib.sha256(content).hexdigest()=='3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a'
    except (OSError,ValueError):return False


'''
after=before.replace('import base64\n','import base64\nimport hashlib\n',1)
needle='def classify(exe: str,args: list[str]) -> str:\n'
assert after.count(needle)==1
after=after.replace(needle,helper+needle,1)
needle='    if stem in CHECK_TOOLS:\n        if any('
assert after.count(needle)==1
after=after.replace(needle,'    if stem in CHECK_TOOLS:\n        if reviewed_sta_collector(exe,args):return "pass"\n        if any(',1)
needle='        if stem not in CHECK_TOOLS:return False\n'
assert after.count(needle)==1
after=after.replace(needle,needle+'        if reviewed_sta_collector(exe,args):return True\n',1)
needle='        if stem in CHECK_TOOLS:\n            allowed='
assert after.count(needle)==1
after=after.replace(needle,'        if stem in CHECK_TOOLS:\n            if reviewed_sta_collector(exe,args):return True\n            allowed=',1)
stage.joinpath('baseline.py').write_bytes(source.read_bytes())
stage.joinpath('candidate.py').write_text(after,encoding='utf-8',newline='\n')
stage.joinpath('candidate.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='baseline.py',tofile='candidate.py')),encoding='utf-8')
old=stage.parent/'queue_guard_read_pipeline/verify.py'
stage.joinpath('verify_original155.py').write_bytes(old.read_bytes())
meta={'baseline_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256(stage.joinpath('candidate.py').read_bytes()).hexdigest(),'collector_sha256':'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a','deployment':False}
stage.joinpath('source_pins.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
print(json.dumps(meta))
