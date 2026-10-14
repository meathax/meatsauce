"""Stage/test the narrow Capsule read-only exemption; deploy only explicitly."""
from pathlib import Path
import difflib
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys

GLOBAL = Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
PREVIOUS = '2fd6ba7bd2bd3e42c89c86196bf274a21d0fda29994923fe3c3333ebc87c9fb7'
RETAINED = Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\research\queue_guard_repair')
STAGE = Path(__file__).resolve().parent / 'capsule_reader_guard'
def digest(data): return hashlib.sha256(data).hexdigest()

if '--deploy' in sys.argv:
    receipt = json.loads((STAGE/'qualification.json').read_text())
    candidate = (STAGE/'shared_quartus_queue_hook.py').read_bytes()
    assert receipt['pass'] and digest(candidate) == receipt['candidate_sha256']
    assert digest(GLOBAL.read_bytes()) == PREVIOUS, 'guard changed since qualification'
    backup = GLOBAL.with_name('shared_quartus_queue_hook.before_capsule_reader_20261010.py')
    if backup.exists(): assert digest(backup.read_bytes()) == PREVIOUS
    else: shutil.copy2(GLOBAL, backup)
    GLOBAL.write_bytes(candidate)
    assert GLOBAL.read_bytes() == candidate
    result = {'deployed_sha256': digest(candidate), 'backup': str(backup), 'backup_sha256': PREVIOUS,
              'queue_controller_worker_changed': False, 'permission_allow_added': False}
    (STAGE/'deployment.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result))
    raise SystemExit(0)

original = GLOBAL.read_bytes()
assert digest(original) == PREVIOUS
text = original.decode('utf-8')
helper = '''def readonly_shell_evidence(command: str, shell: str) -> bool:
    """Only one literal read command; rg's executable preprocessor is excluded."""
    try:
        tokens=words(command,shell)
        if not tokens:return False
        if tokens[0].lower() in READERS:
            if tokens[0].lower()=='rg' and any(a.lower()=='--pre' or a.lower().startswith('--pre=') for a in tokens[1:]):return False
            return True
        exe,args=unwrap(tokens,shell)
        if ntpath.basename(exe).lower() in {'python','python.exe','python3','python3.exe'}:
            return readonly_python(args)
        return False
    except (Refusal,ValueError,IndexError):return False


'''
marker = 'def classify(exe: str,args: list[str]) -> str:'
assert text.count(marker) == 1
text = text.replace(marker, helper+marker)
old = '        if token and token[0].lower() in READERS:return None,None'
assert text.count(old) == 1
text = text.replace(old, '        if readonly_shell_evidence(command,shell):return None,None')
old = '''    else:
        # Unknown typed MCP execution cannot be safely converted into shell syntax.
'''
new = '''    else:
        # Capsule run is a known command carrier. Exempt only the same finite
        # read grammar; never convert, forward, approve or launch Quartus here.
        if name=="mcp__capsule__capsule" and inp.get("action")=="run":
            packet=inp.get("payload")
            if isinstance(packet,dict) and packet.get("args",[])==[]:
                literal=packet.get("command")
                if isinstance(literal,str) and readonly_shell_evidence(literal,default_shell):return {}
        # Unknown typed MCP execution cannot be safely converted into shell syntax.
'''
assert text.count(old) == 1
text = text.replace(old, new)
candidate = text.encode('utf-8')
STAGE.mkdir(parents=True, exist_ok=True)
(STAGE/'shared_quartus_queue_hook.py').write_bytes(candidate)
(STAGE/'predecessor.py').write_bytes(original)
(STAGE/'guard.patch').write_text(''.join(difflib.unified_diff(original.decode().splitlines(True), text.splitlines(True), fromfile='shared_quartus_queue_hook.py', tofile='shared_quartus_queue_hook.py')), encoding='utf-8')
for name in ['test_guard.py','shared_quartus_queue_hook.original.py']:
    shutil.copy2(RETAINED/name, STAGE/name)
(STAGE/'manifest.json').write_text(json.dumps({'original_path':str(GLOBAL),'candidate_sha256':digest(candidate)}, indent=2)+'\n', encoding='utf-8')
run = subprocess.run([sys.executable,str(STAGE/'test_guard.py')], capture_output=True, text=True)
(STAGE/'legacy_test_terminal.json').write_text(json.dumps({'exit_code':run.returncode,'stdout':run.stdout,'stderr':run.stderr}, indent=2)+'\n', encoding='utf-8')
assert run.returncode == 0, (run.stdout,run.stderr)
spec = importlib.util.spec_from_file_location('capsule_guard_candidate', STAGE/'shared_quartus_queue_hook.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
exact = "rg -n --max-count 8 --max-columns 220 'registry.*approval|registration.*pending|lease.*map|map.*lease|preassembly.*queue|All Quartus use is suspended|Quartus.*held|Quartus hold' AGENTS.md plan.md goal_prompt.md docs tools scripts quartus_hold.json"
cases = [
    ('actual_readonly_queue_search',exact,True,'mcp__capsule__capsule','run',[]),
    ('quoted_unsafe_name_is_only_data',"rg 'quartus_asm|Stop-Process quartus*' AGENTS.md",True,'mcp__capsule__capsule','run',[]),
    ('typed_python_evidence',"python -c \"print('quartus_hold.json')\"",True,'mcp__capsule__capsule','run',[]),
    ('raw_assembly',r'quartus_asm Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
    ('raw_full_compile',r'quartus_sh --flow compile Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
    ('typed_check_not_forwarded',r'quartus_fit Alpha68k_N',False,'mcp__capsule__capsule','run',[]),
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
for name,command,allowed,tool,action,args in cases:
    event={'tool_name':tool,'tool_input':{'action':action,'payload':{'command':command,'args':args}},'cwd':str(STAGE)}
    result=g.adapt(event,'codex','powershell',True)
    assert (result=={}) == allowed, (name,result)
    assert 'permissionDecision' not in str(result) if allowed else True
    results.append({'name':name,'normal_review_only':allowed,'result':result})
for command in ["rg --pre=quartus_asm x AGENTS.md","rg --pre quartus_asm x AGENTS.md"]:
    replacement,error=g.adapt_shell(command,'powershell',str(STAGE))
    assert replacement is None and error is not None
qualification={'pass':True,'previous_sha256':PREVIOUS,'candidate_sha256':digest(candidate),
               'legacy_cases':len(json.loads((STAGE/'test_receipt.json').read_text())['results']),
               'capsule_cases':len(results),'direct_reader_negative_cases':2,'results':results,
               'limits':'Pure classification only; no Quartus jobs, negatives, queues or unsafe commands executed. Allowed reads return {} for ordinary review.'}
(STAGE/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:qualification[k] for k in ['pass','previous_sha256','candidate_sha256','legacy_cases','capsule_cases','direct_reader_negative_cases']}))
