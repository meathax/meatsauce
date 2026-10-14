"""Pure hook classification only. Test command strings are never executed."""
import hashlib,json,types
from pathlib import Path
S=Path(__file__).resolve().parent
P=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
data=P.read_bytes();digest=hashlib.sha256(data).hexdigest()
expected='25307fcc82a89954efe918a7b916cb807a034528c98e81806e380f010cc0654c'
assert digest==expected,('Global revision changed; do not misattribute old classification',digest)
(S/'reviewed_guard25307.py').write_bytes(data)
g=types.ModuleType('independent_pure_guard_review');g.__file__=str(P)
exec(compile(data,str(P),'exec'),g.__dict__)
cases=[
    ('benign_quoted_tool_literal',"rg -n 'quartus_asm' source.txt",True),
    ('unquoted_LF_delegate',"rg pattern source.txt\nquartus_asm project",False),
    ('unquoted_CRLF_delegate',"rg pattern source.txt\r\nD:\\q17\\bin64\\quartus_asm.exe project",False),
    ('quoted_multiline_data',"rg -n 'first\nquartus_asm' source.txt",True)]
results=[]
for name,command,expected_reader in cases:
    event={'tool_name':'mcp__capsule__capsule','tool_input':{'action':'run','payload':{'command':command,'args':[]}},'cwd':str(S)}
    reader=g.readonly_shell_evidence(command,'powershell')
    result=g.adapt(event,'codex','powershell',True)
    expected_deny=not expected_reader
    denied=result.get('hookSpecificOutput',{}).get('permissionDecision')=='deny'
    results.append({'name':name,'command_is_test_data_only':command,'expected_reader':expected_reader,
        'actual_reader':reader,'expected_deny':expected_deny,'actual_deny':denied,'hook_result':result,
        'passed':reader==expected_reader and denied==expected_deny})
r={'scope':'Independent pure classification of reader Capsule exception; no command execution/deployment/FPGA job.',
    'reviewed_source_sha256':digest,'reviewer_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'results':results,'all_cases_pass':all(x['passed'] is True for x in results),
    'finding':'Outside quoted strings, CR/LF are consumed by isspace before the forbidden-syntax check. A reader prefix can therefore exempt an actual second shell command from the typed Quartus fence.',
    'minimal_correction':'Reject unquoted CR/LF before isspace, preserving quoted multiline data and existing typed Python validation.',
    'unsafe_test_commands_executed':False,'global_guard_modified':False}
p=S/'original25307_review.json';p.write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps({'source_sha256':digest,'cases':len(results),'passed':sum(x['passed'] is True for x in results),
    'failed':[x['name'] for x in results if not x['passed']],'receipt_sha256':hashlib.sha256(p.read_bytes()).hexdigest()}))
raise SystemExit(0 if r['all_cases_pass'] else 1)
