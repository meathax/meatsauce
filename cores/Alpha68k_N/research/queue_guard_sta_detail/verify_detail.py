from pathlib import Path
import importlib.util,hashlib,json,runpy
from unittest.mock import patch
root=Path(__file__).parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('baseline_detail',root/'baseline.py');g=load('candidate_detail',root/'candidate.py')
pins=json.loads((root/'source_pins.json').read_text())
assert hashlib.sha256((root/'candidate.py').read_bytes()).hexdigest()==pins['candidate_sha256']
# Preserve every previous test case; only original collector positive assertions
# change from baseline-denied to baseline-allowed because294 deployed that fix.
prior=(root/'verify_collector.py').read_text()
prior=prior.replace("assert old['hookSpecificOutput']['permissionDecision']=='deny'", "assert old==new")
exec(compile(prior,str(root/'verify_collector.py'),'exec'),{'__file__':str(root/'verify_collector.py'),'__name__':'original181_replay'})
prior_receipt=json.loads((root/'collector_qualification.json').read_text())
assert prior_receipt['total_checks']==181 and prior_receipt['pass']
exe=r'D:\q17\quartus\bin64\quartus_sta.exe'
collector=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners-detail.tcl'
project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
destination=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
args=['-t',collector,project,'Alpha68k_N',destination]
q=lambda value:"'"+value.replace("'","''")+"'"
cmd=lambda tool,arguments:'& '+q(tool)+' '+' '.join(q(a) for a in arguments)
results=[]
def check(name,tool,arguments,accepted):
    command=cmd(tool,arguments)
    assert g.reviewed_sta_collector(tool,arguments)==accepted,name
    event={'tool_name':'exec_command','tool_input':{'cmd':command,'workdir':str(root)}}
    old=b.adapt(event,'codex','powershell',True);new=g.adapt(event,'codex','powershell',True)
    if accepted:
        assert old['hookSpecificOutput']['permissionDecision']=='deny'
        assert new['hookSpecificOutput']['permissionDecision']=='allow'
        assert 'updatedInput' not in new['hookSpecificOutput']
    else:assert old==new,(name,old,new)
    results.append({'name':name,'command':command,'accepted_collector':accepted,'baseline':old,'candidate':new})
check('detail_exact',exe,args,True)
check('detail_native_spelling',exe,[args[0],collector.replace('/','\\'),project.replace('/','\\'),args[3],destination.replace('/','\\')],True)
for name,index,value in [('other_script',1,collector+'.bad'),('other_project',2,project+'2'),('other_revision',3,'Other'),('other_destination',4,destination+'2'),('relative_collector',1,'all-corners-detail.tcl'),('relative_destination',4,'all-corners'),('alternate_delegate',0,'--script')]:
    changed=args.copy();changed[index]=value;check(name,exe,changed,False)
for tool in [r'D:\other\quartus_sta.exe',r'D:\q17\quartus\bin\quartus_sta.exe',r'D:\q17\quartus\bin64\quartus_asm.exe',r'D:\q17\quartus\bin64\quartus_sh.exe']:
    check('wrong_tool_'+tool,tool,args,False)
for extra in ['--eval','--allow-rbf','-t']:
    check('extra_'+extra,exe,args+[extra],False)
check('missing_argument',exe,args[:-1],False)
for name,changed in [('modified_script',b'puts changed'),('oversized_script',b'x'*65537)]:
    with patch.object(g,'open',create=True) as opened:
        opened.return_value.__enter__.return_value.read.return_value=changed
        assert not g.reviewed_sta_collector(exe,args)
        event={'tool_name':'exec_command','tool_input':{'cmd':cmd(exe,args)}}
        assert g.adapt(event,'codex','powershell',True)['hookSpecificOutput']['permissionDecision']=='deny'
        results.append({'name':name,'accepted_collector':False})
with patch.object(g,'open',create=True,side_effect=OSError('missing')):
    assert not g.reviewed_sta_collector(exe,args)
    results.append({'name':'missing_script','accepted_collector':False})
for suffix in ['; quartus_asm x','\nquartus_asm x',' | quartus_asm x']:
    event={'tool_name':'exec_command','tool_input':{'cmd':cmd(exe,args)+suffix}}
    assert g.adapt(event,'codex','powershell',True)['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':'compound_'+repr(suffix),'accepted_collector':False})
receipt={'pass':True,'baseline_sha256':pins['baseline_sha256'],'candidate_sha256':pins['candidate_sha256'],'detail_collector_sha256':pins['detail_collector_sha256'],'prior181_replayed':True,'new_cases':len(results),'total_checks':181+len(results),'global_deployment':False,'results':results}
(root/'detail_qualification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
