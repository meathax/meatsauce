from pathlib import Path
import importlib.util,hashlib,json
from unittest.mock import patch
root=Path(__file__).parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('baseline_standard',root/'baseline.py');g=load('candidate_standard',root/'candidate.py')
pins=json.loads((root/'source_pins.json').read_text())
assert hashlib.sha256((root/'candidate.py').read_bytes()).hexdigest()==pins['candidate_sha256']
prior=json.loads((root/'detail_qualification.json').read_text())
assert prior['pass'] and prior['total_checks']==204
exe=r'D:\q17\quartus\bin64\quartus_sta.exe'
collector=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners-detail.tcl'
old_collector=collector.replace('all-corners-detail.tcl','all-corners.tcl')
project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_standard_fit/Alpha68k_N'
old_project=project.replace('case2_standard_fit/','case2_full_map/')
output=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_standard_fit_evidence/all-corners'
old_output=output.replace('case2_standard_fit_evidence/','case2_fit_sta/')
args=['-t',collector,project,'Alpha68k_N',output]
q=lambda value:"'"+value.replace("'","''")+"'"
command=lambda tool,arguments:'& '+q(tool)+' '+' '.join(q(a) for a in arguments)
results=[]
def check(name,tool,arguments,approved):
    cmd=command(tool,arguments)
    assert g.reviewed_sta_collector(tool,arguments)==approved,name
    event={'tool_name':'exec_command','tool_input':{'cmd':cmd,'workdir':str(root)}}
    old=b.adapt(event,'codex','powershell',True);new=g.adapt(event,'codex','powershell',True)
    if approved:
        assert old['hookSpecificOutput']['permissionDecision']=='deny'
        assert new['hookSpecificOutput']['permissionDecision']=='allow'
        assert 'updatedInput' not in new['hookSpecificOutput']
    else:assert old==new,(name,old,new)
    results.append({'name':name,'command':cmd,'approved':approved,'baseline':old,'candidate':new})
check('standard_exact_tuple',exe,args,True)
check('standard_native_spelling',exe,[args[0],collector.replace('/','\\'),project.replace('/','\\'),args[3],output.replace('/','\\')],True)
for name,index,value in [('cross_original_output',4,old_output),('cross_original_project',2,old_project),('original_collector_on_standard',1,old_collector),('other_script',1,collector+'.bad'),('other_project',2,project+'2'),('other_output',4,output+'2'),('relative_project',2,'Alpha68k_N'),('relative_output',4,'all-corners'),('other_revision',3,'other'),('other_delegate',0,'--script')]:
    changed=args.copy();changed[index]=value;check(name,exe,changed,False)
for tool in [r'D:\other\quartus_sta.exe',r'D:\q17\quartus\bin\quartus_sta.exe',r'D:\q17\quartus\bin64\quartus_sh.exe',r'D:\q17\quartus\bin64\quartus_asm.exe',r'D:\q17\quartus\bin64\quartus_cpf.exe']:
    check('wrong_tool_'+tool,tool,args,False)
for extra in ['--eval','-t','--allow-rbf']:
    check('extra_'+extra,exe,args+[extra],False)
check('missing_arg',exe,args[:-1],False)
for name,data in [('changed_hash',b'puts changed'),('oversized',b'x'*65537)]:
    with patch.object(g,'open',create=True) as mocked:
        mocked.return_value.__enter__.return_value.read.return_value=data
        assert not g.reviewed_sta_collector(exe,args)
        new=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':command(exe,args)}},'codex','powershell',True)
        assert new['hookSpecificOutput']['permissionDecision']=='deny'
        results.append({'name':name,'approved':False})
with patch.object(g,'open',create=True,side_effect=OSError('missing')):
    assert not g.reviewed_sta_collector(exe,args)
    results.append({'name':'missing_collector','approved':False})
for suffix in ['; quartus_asm x','\nquartus_asm x',' | quartus_asm x']:
    new=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':command(exe,args)+suffix}},'codex','powershell',True)
    assert new['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':'compound_'+repr(suffix),'approved':False})
receipt={'pass':True,'baseline_sha256':pins['baseline_sha256'],'candidate_sha256':pins['candidate_sha256'],'detail_collector_sha256':pins['detail_collector_sha256'],'prior204_replayed':True,'new_cases':len(results),'total_checks':204+len(results),'global_deployment':False,'results':results}
(root/'standard_qualification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
