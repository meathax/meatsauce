from pathlib import Path
import importlib.util,json,hashlib
from unittest.mock import patch
root=Path(__file__).parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('baseline_sta',root/'baseline.py');g=load('candidate_sta',root/'candidate.py')
pins=json.loads((root/'source_pins.json').read_text())
assert hashlib.sha256((root/'candidate.py').read_bytes()).hexdigest()==pins['candidate_sha256']
q=lambda value:"'"+value.replace("'","''")+"'"
exe=r'D:\q17\quartus\bin64\quartus_sta.exe'
collector=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners.tcl'
project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
destination=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
args=['-t',collector,project,'Alpha68k_N',destination]
command=lambda tool,arguments:'& '+q(tool)+' '+' '.join(q(a) for a in arguments)
results=[]
def verify(name,tool,arguments,approved):
    cmd=command(tool,arguments)
    assert g.reviewed_sta_collector(tool,arguments)==approved,name
    event={'tool_name':'exec_command','tool_input':{'cmd':cmd,'workdir':str(root)}}
    old=b.adapt(event,'codex','powershell',True);new=g.adapt(event,'codex','powershell',True)
    if approved:
        assert old['hookSpecificOutput']['permissionDecision']=='deny'
        assert new['hookSpecificOutput']['permissionDecision']=='allow'
        assert 'updatedInput' not in new['hookSpecificOutput']
        assert g.adapt_shell(cmd,'powershell',str(root))==(None,None)
    else:assert old==new,(name,old,new)
    results.append({'name':name,'command':cmd,'approved_collector':approved,'baseline':old,'candidate':new})
verify('exact_rejected_command',exe,args,True)
verify('windows_path_spelling',exe,[args[0],collector.replace('/','\\'),project.replace('/','\\'),args[3],destination.replace('/','\\')],True)
for label,index,value in [('other_collector',1,r'D:\other\all-corners.tcl'),('other_project',2,r'D:\other\Alpha68k_N'),('other_revision',3,'other'),('other_output',4,r'D:\other'),('relative_collector',1,'all-corners.tcl'),('relative_output',4,'all-corners'),('arbitrary_eval',0,'--eval'),('equals_script',0,'-t='+collector)]:
    changed=args.copy();changed[index]=value;verify(label,exe,changed,False)
for other in [r'D:\other\quartus_sta.exe',r'D:\q17\quartus\bin\quartus_sta.exe',r'D:\q17\quartus\bin64\quartus_sh.exe',r'D:\q17\quartus\bin64\quartus_asm.exe',r'D:\q17\quartus\bin64\quartus_cpf.exe']:
    verify('wrong_tool_'+other,other,args,False)
for extra in ['--flow','--allow-rbf','--script','-t']:
    verify('extra_'+extra,exe,args+[extra],False)
verify('missing_output',exe,args[:-1],False)
for label,side_effect,return_value in [('changed_hash',None,b'puts bad\n'),('missing_collector',OSError('missing'),None),('oversized_collector',None,b'x'*65537)]:
    with patch.object(g,'open',create=True) as mocked:
        if side_effect:mocked.side_effect=side_effect
        else:mocked.return_value.__enter__.return_value.read.return_value=return_value
        assert not g.reviewed_sta_collector(exe,args),label
        out=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':command(exe,args)}},'codex','powershell',True)
        assert out['hookSpecificOutput']['permissionDecision']=='deny',label
        results.append({'name':label,'approved_collector':False,'candidate':out})
for suffix in ['; quartus_asm x','\nquartus_asm x',' | quartus_asm x']:
    out=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':command(exe,args)+suffix}},'codex','powershell',True)
    assert out['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':'compound_'+repr(suffix),'candidate':out})
original=json.loads((root/'qualification.json').read_text())
assert original['pass'] and original['checks']==155
receipt={'pass':True,'baseline_sha256':pins['baseline_sha256'],'candidate_sha256':pins['candidate_sha256'],'collector_sha256':pins['collector_sha256'],'prior155_pass':True,'new_cases':len(results),'total_checks':155+len(results),'global_deployment':False,'queue_workers_modified':False,'results':results}
(root/'collector_qualification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
