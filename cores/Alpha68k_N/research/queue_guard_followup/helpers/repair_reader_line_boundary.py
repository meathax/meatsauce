"""Reject unquoted command newlines; preserve quoted read-only Python code."""
from pathlib import Path
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys

GLOBAL = Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
PREVIOUS = '25307fcc82a89954efe918a7b916cb807a034528c98e81806e380f010cc0654c'
RETAINED = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\research\queue_guard_repair')
STAGE = Path(__file__).resolve().parent / 'capsule_reader_guard_newline_fix'
def digest(data): return hashlib.sha256(data).hexdigest()
def module(path, name):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result)
    return result

if '--deploy' in sys.argv:
    receipt=json.loads((STAGE/'qualification.json').read_text())
    candidate=(STAGE/'shared_quartus_queue_hook.py').read_bytes()
    assert receipt['pass'] and digest(candidate)==receipt['candidate_sha256']
    assert digest(GLOBAL.read_bytes())==PREVIOUS
    backup=GLOBAL.with_name('shared_quartus_queue_hook.before_reader_line_boundary_20261010.py')
    if backup.exists():assert digest(backup.read_bytes())==PREVIOUS
    else:shutil.copy2(GLOBAL,backup)
    GLOBAL.write_bytes(candidate)
    assert GLOBAL.read_bytes()==candidate
    result={'deployed_sha256':digest(candidate),'backup':str(backup),'backup_sha256':PREVIOUS,
            'queue_controller_worker_changed':False,'permission_allow_added':False}
    (STAGE/'deployment.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result));raise SystemExit(0)

before=GLOBAL.read_bytes();assert digest(before)==PREVIOUS
text=before.decode('utf-8')
old='''        if c.isspace():
            if active:out.append("".join(token));token=[];active=False
'''
new='''        if c in "\\r\\n":raise Refusal("Multiple command lines are unsupported")
        if c.isspace():
            if active:out.append("".join(token));token=[];active=False
'''
assert text.count(old)==1
candidate=text.replace(old,new).encode('utf-8')
STAGE.mkdir(parents=True,exist_ok=True)
(STAGE/'shared_quartus_queue_hook.py').write_bytes(candidate)
(STAGE/'predecessor.py').write_bytes(before)
for name in ['test_guard.py','shared_quartus_queue_hook.original.py']:shutil.copy2(RETAINED/name,STAGE/name)
(STAGE/'manifest.json').write_text(json.dumps({'original_path':str(GLOBAL),'candidate_sha256':digest(candidate)},indent=2)+'\n',encoding='utf-8')
run=subprocess.run([sys.executable,str(STAGE/'test_guard.py')],capture_output=True,text=True)
(STAGE/'legacy_test_terminal.json').write_text(json.dumps({'exit_code':run.returncode,'stdout':run.stdout,'stderr':run.stderr},indent=2)+'\n',encoding='utf-8')
assert run.returncode==0,(run.stdout,run.stderr)
g=module(STAGE/'shared_quartus_queue_hook.py','line_guard_candidate')
prior=module(STAGE/'predecessor.py','line_guard_previous')
exact="rg -n --max-count 8 --max-columns 220 'registry.*approval|registration.*pending|lease.*map|map.*lease|preassembly.*queue|All Quartus use is suspended|Quartus.*held|Quartus hold' AGENTS.md plan.md goal_prompt.md docs tools scripts quartus_hold.json"
cases=[
 ('actual_readonly_queue_search',exact,True,'mcp__capsule__capsule','run',[]),
 ('quoted_tool_and_kill_data',"rg 'quartus_asm|Stop-Process quartus*' AGENTS.md",True,'mcp__capsule__capsule','run',[]),
 ('typed_python_evidence',"python -c \"print('quartus_hold.json')\"",True,'mcp__capsule__capsule','run',[]),
 ('raw_assembly','quartus_asm Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
 ('raw_full_compile','quartus_sh --flow compile Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
 ('typed_check_not_forwarded','quartus_fit Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
 ('unknown_mcp_reader',exact,False,'mcp__other__runner','run',[]),
 ('wrong_action',exact,False,'mcp__capsule__capsule','other',[]),
 ('hidden_additional_args',exact,False,'mcp__capsule__capsule','run',['--pre=quartus_asm']),
 ('reader_chain',"rg 'quartus_hold' AGENTS.md; quartus_asm x",False,'mcp__capsule__capsule','run',[]),
 ('reader_preprocessor',"rg --pre=quartus_asm x AGENTS.md",False,'mcp__capsule__capsule','run',[]),
 ('reader_preprocessor_separate',"rg --pre quartus_asm x AGENTS.md",False,'mcp__capsule__capsule','run',[]),
 ('reader_substitution',"rg $(quartus_asm x) AGENTS.md",False,'mcp__capsule__capsule','run',[]),
 ('python_execution',"python -c \"import os; os.system('quartus_asm x')\"",False,'mcp__capsule__capsule','run',[]),
]
results=[]
def event(command,tool='mcp__capsule__capsule',action='run',args=None):
    return {'tool_name':tool,'tool_input':{'action':action,'payload':{'command':command,'args':args or []}},'cwd':str(STAGE)}
proof=event('rg pattern file\nquartus_asm project')
assert prior.adapt(proof,'codex','powershell',True)=={},'independent concern not reproduced'
for name,command,allowed,tool,action,args in cases:
    result=g.adapt(event(command,tool,action,args),'codex','powershell',True)
    assert (result=={})==allowed,(name,result)
    results.append({'name':name,'command':command,'normal_review_only':allowed,'result':result})
boundary=[]
for separator in ['\n','\r','\r\n']:
    for reader in ['rg pattern file','echo quartus_hold.json']:
        command=reader+separator+'quartus_asm project'
        typed=g.adapt(event(command),'codex','powershell',True)
        direct=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':command}},'codex','powershell',True)
        assert typed!={} and direct!={}
        boundary.append({'command':command,'typed_result':typed,'direct_result':direct})
quoted="python -c \"from pathlib import Path; print('quartus_hold.json');\nprint('read only')\""
assert g.adapt(event(quoted),'codex','powershell',True)=={}
for command in ["rg --pre=quartus_asm x AGENTS.md","rg --pre quartus_asm x AGENTS.md"]:
    replacement,error=g.adapt_shell(command,'powershell',str(STAGE))
    assert replacement is None and error is not None
receipt={'pass':True,'previous_sha256':PREVIOUS,'candidate_sha256':digest(candidate),
 'legacy_cases':len(json.loads((STAGE/'test_receipt.json').read_text())['results']),
 'typed_cases':len(results),'line_boundary_typed_and_direct_cases':len(boundary)*2,
 'quoted_multiline_case':1,'direct_preprocessor_negative_cases':2,
 'previous_bug_reproduced_purely':True,'typed_results':results,'boundary_results':boundary,
 'limits':'Pure classification only; no unsafe commands, tools or queue jobs executed. Normal reads return {} for ordinary review; no permission allow added.'}
(STAGE/'qualification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:receipt[k] for k in ['pass','candidate_sha256','legacy_cases','typed_cases','line_boundary_typed_and_direct_cases','quoted_multiline_case','direct_preprocessor_negative_cases','previous_bug_reproduced_purely']}))
