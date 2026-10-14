from pathlib import Path
import importlib.util, hashlib, json, base64, sys, ast

root=Path(__file__).parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('baseline',root/'baseline.py');g=load('candidate',root/'candidate.py')
results=[]
def check(name,command,allowed):
    for shell in ['powershell']:
        baseline=b.adapt_shell(command,shell,str(root));candidate=g.adapt_shell(command,shell,str(root))
        event={'tool_name':'exec_command','tool_input':{'cmd':command,'workdir':str(root)}}
        x=b.adapt(event,'codex',shell,True);y=g.adapt(event,'codex',shell,True)
        assert baseline==candidate and x==y,(name,baseline,candidate,x,y)
        assert (candidate[1] is None)==allowed,(name,candidate)
        results.append({'name':name,'command':command,'class':'unchanged','baseline':x,'candidate':y})
archive=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N\research\queue_guard_followup')
legacy=archive/'final_line_boundary_fix/test_guard.py'
tree=ast.parse(legacy.read_text())
# Reuse the original 69 command-construction/tests without its obsolete hook
# approval expectation (V2 now grants standing approval to literal checks).
body=tree.body
start=next(i for i,n in enumerate(body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='fast' for t in n.targets))
stop=next(i for i,n in enumerate(body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='original' for t in n.targets))
filtered=[n for n in body[start:stop] if not (isinstance(n,ast.FunctionDef) and n.name=='check')]
exec(compile(ast.Module(body=filtered,type_ignores=[]),str(legacy),'exec'),globals())
legacy_count=len(results)
# Replay the remaining 29 exact prior checks from its retained construction
# source, preserving typed carrier options and direct/typed newline coverage.
prior_helper=Path(r'D:\Arcade\AI\aCORES\Alpha68k N\research\integration_phase_stage\repair_reader_line_boundary.py')
prior_ast=ast.parse(prior_helper.read_text())
scope={}
for node in prior_ast.body:
    if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id in {'exact','cases'} for t in node.targets):
        exec(compile(ast.Module(body=[node],type_ignores=[]),str(prior_helper),'exec'),scope)
def typed_event(command,tool='mcp__capsule__capsule',action='run',args=None):
    return {'tool_name':tool,'tool_input':{'action':action,'payload':{'command':command,'args':args or []}},'cwd':str(root)}
for name,command,allowed,tool,action,args in scope['cases']:
    event=typed_event(command,tool,action,args)
    baseline=b.adapt(event,'codex','powershell',True);candidate=g.adapt(event,'codex','powershell',True)
    assert baseline==candidate and (candidate=={})==allowed,(name,baseline,candidate)
    results.append({'name':name,'class':'original_typed_unchanged','command':command,'baseline':baseline,'candidate':candidate})
for separator in ['\n','\r','\r\n']:
    for reader in ['rg pattern file','echo quartus_hold.json']:
        command=reader+separator+'quartus_asm project'
        for event in [typed_event(command),{'tool_name':'exec_command','tool_input':{'cmd':command}}]:
            baseline=b.adapt(event,'codex','powershell',True);candidate=g.adapt(event,'codex','powershell',True)
            assert baseline==candidate and candidate!={}
            results.append({'name':'original_boundary','command':command,'baseline':baseline,'candidate':candidate})
quoted="python -c \"from pathlib import Path; print('quartus_hold.json');\nprint('read only')\""
assert b.adapt(typed_event(quoted),'codex','powershell',True)==g.adapt(typed_event(quoted),'codex','powershell',True)=={}
results.append({'name':'original_quoted_multiline','command':quoted,'class':'unchanged'})
for command in ['rg --pre=quartus_asm x AGENTS.md','rg --pre quartus_asm x AGENTS.md']:
    assert b.adapt_shell(command,'powershell',str(root))==g.adapt_shell(command,'powershell',str(root))
    assert g.adapt_shell(command,'powershell',str(root))[1] is not None
    results.append({'name':'original_direct_preprocessor','command':command,'class':'unchanged'})
original_98_count=len(results)
assert original_98_count==98,original_98_count
literal=r"Get-Content -LiteralPath 'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py' | Select-Object -Skip 440 -First 70"
cases=[('actual_bounded_file',literal,True),
 ('cim_literal_filter',"Get-CimInstance -ClassName Win32_Process -Filter \"Name LIKE 'quartus%'\" | Select-Object ProcessId,ParentProcessId,Name,CommandLine | Format-List",True),
 ('cim_filter_projection',"Get-CimInstance Win32_Process -Filter \"Name='quartus_map.exe'\" | Select-Object -Property ProcessId,CommandLine -First 4",True),
 ('cim_single',"Get-CimInstance Win32_Process -Filter \"Name='quartus_map.exe'\"",True),
 ('unbounded_file',literal.replace(' -First 70',''),False),
 ('scriptblock',literal+' | ForEach-Object { quartus_asm }',False),
 ('calculated_property',literal.replace('-Skip 440 -First 70','-Property @{Name=\'quartus\';Expression={1}}'),False),
 ('write_stage',literal+' | Set-Content quartus.txt',False),
 ('substitution',literal.replace('-Skip 440','-Skip $(quartus_asm)'),False),
 ('pipeline_background',literal+' & quartus_asm',False),
 ('remote_cim',"Get-CimInstance Win32_Process -ComputerName quartus_host | Format-List",False),
 ('provider_cim',"Get-CimInstance Win32_Service -Filter \"Name='quartus'\" | Format-List",False),
 ('method_cim',"Get-CimInstance Win32_Process -Filter \"Name='quartus'\" | Invoke-CimMethod -MethodName Terminate",False),
 ('rg_pre','rg --pre quartus_asm quartus',False),
 ('rg_pre_equals','rg --pre=quartus_asm quartus',False),
 ('empty_stage',literal.replace(' | ',' || '),False),
 ('projection_alias',literal.replace('Select-Object','select'),False),
 ('zero_bound',literal.replace('-First 70','-First 0'),False),
 ('too_large_bound',literal.replace('-First 70','-First 10001'),False)]
for sep in ['\n','\r','\r\n']:
    cases.extend([(f'newline_{sep!r}',literal+sep+'quartus_asm x',False),
                  (f'newline_stage_{sep!r}',literal.replace('|','|'+sep),False)])
for name,command,expected in cases:
    old=b.readonly_shell_evidence(command,'powershell');new=g.readonly_shell_evidence(command,'powershell')
    assert new==expected,(name,old,new)
    for carrier in ['exec','capsule']:
        event={'tool_name':'exec_command','tool_input':{'cmd':command}} if carrier=='exec' else {'tool_name':'mcp__capsule__capsule','tool_input':{'action':'run','payload':{'command':command,'cwd':str(root),'capsule_force':True}}}
        output=g.adapt(event,'codex','powershell',True)
        if expected:assert output=={},(name,carrier,output)
        else:assert output==b.adapt(event,'codex','powershell',True),(name,carrier,output)
        results.append({'name':name,'command':command,'carrier':carrier,'read_exemption':new,'baseline_read_exemption':old,'output':output})
# Preserve quoted multiline evidence data and the original reader boundary.
check('quoted_multiline_python',"python -c 'print(\"quartus\")\nprint(\"data\")'",True)
for separator in ['\n','\r','\r\n']:
    for reader in ["rg --max-count 1 quartus_hold.json .", "Get-Content -LiteralPath quartus_hold.json"]:
        check('legacy_reader_newline_'+repr(separator),reader+separator+'quartus_asm x',False)
receipt={'pass':True,'baseline_sha256':hashlib.sha256((root/'baseline.py').read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256((root/'candidate.py').read_bytes()).hexdigest(),'original_98_replayed':original_98_count,'checks':len(results),'global_deployment':False,'results':results}
(root/'qualification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
