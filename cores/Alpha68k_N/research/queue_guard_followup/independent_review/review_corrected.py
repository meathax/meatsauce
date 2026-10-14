"""Independent pure four-case retest and exact guard delta review."""
import ast,difflib,hashlib,json,types
from pathlib import Path
S=Path(__file__).resolve().parent
P=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
data=P.read_bytes();digest=hashlib.sha256(data).hexdigest()
assert digest=='f38be3c621d0c0d4127356fd85c76d7e2cdbd4e23ae740ed8e8b457dfae5992b',digest
old=(S/'reviewed_guard25307.py').read_text();new=data.decode()
diff=list(difflib.ndiff(old.splitlines(),new.splitlines()))
added=[x[2:] for x in diff if x.startswith('+ ')];removed=[x[2:] for x in diff if x.startswith('- ')]
assert len(added)==1 and not removed,(added,removed)
line=added[0];assert line.startswith('        if c in "\\r\\n":raise Refusal('),line
assert new.replace(line+'\n','',1)==old,'Other content changed'
assert new.index(line)<new.index('        if c.isspace():')
# Cases are extracted as literal data without executing the previous reviewer.
tree=ast.parse((S/'review.py').read_text())
cases=ast.literal_eval(next(x.value for x in tree.body if isinstance(x,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='cases' for t in x.targets)))
g=types.ModuleType('independent_corrected_guard_review');g.__file__=str(P)
exec(compile(data,str(P),'exec'),g.__dict__)
results=[]
for name,command,expected_reader in cases:
    event={'tool_name':'mcp__capsule__capsule','tool_input':{'action':'run','payload':{'command':command,'args':[]}},'cwd':str(S)}
    reader=g.readonly_shell_evidence(command,'powershell');result=g.adapt(event,'codex','powershell',True)
    denied=result.get('hookSpecificOutput',{}).get('permissionDecision')=='deny'
    results.append({'name':name,'actual_reader':reader,'actual_deny':denied,'hook_result':result,
        'passed':reader==expected_reader and denied==(not expected_reader)})
receipt={'scope':'Independent exact narrow guard correction and same4 pure cases; no unsafe command execution.',
    'previous_source_sha256':hashlib.sha256((S/'reviewed_guard25307.py').read_bytes()).hexdigest(),
    'deployed_source_sha256':digest,'only_added_line':line,'all_other_content_exact':True,
    'unquoted_newline_refusal_before_whitespace':True,'quoted_branch_unchanged':True,
    'results':results,'all_cases_pass':all(x['passed'] is True for x in results),
    'original_failure_receipt_sha256':hashlib.sha256((S/'original25307_review.json').read_bytes()).hexdigest(),
    'unsafe_test_commands_executed':False,'global_guard_modified':False,
    'limits':['The hook returns ordinary permission review for benign readers; it does not authorize or execute them.','Executable startup/import/environment behavior remains outside this finite literal classifier.']}
p=S/'corrected_f38_review.json';p.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'cases':len(results),'passed':sum(x['passed'] is True for x in results),'exact_narrow_delta':line,
    'receipt_sha256':hashlib.sha256(p.read_bytes()).hexdigest()}))
raise SystemExit(0 if receipt['all_cases_pass'] else 1)
