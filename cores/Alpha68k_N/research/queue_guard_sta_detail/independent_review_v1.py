from pathlib import Path
import ast, base64, hashlib, importlib.util, json, subprocess, sys
from unittest.mock import patch

root=Path(__file__).parent
if '--worker' not in sys.argv:
    for name in ['independent_review_v1.json','independent_review_v1.log','independent_review_v1_exit.json']:
        assert not (root/name).exists(), 'Immutable review output already exists: '+name
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'independent_review_v1.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'dangerous_commands_executed':False}
    (root/'independent_review_v1_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr)
    sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
baseline=root/'baseline.py';candidate=root/'candidate.py'
global_path=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
collector_root=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta')
detail=collector_root/'all-corners-detail.tcl';original=collector_root/'all-corners.tcl'
pins={'baseline':sha(baseline),'candidate':sha(candidate),'global':sha(global_path),'original_collector':sha(original),'detail_collector':sha(detail)}
assert pins=={'baseline':'294f6b5d02bd99f316b50a880a2e9376afcbcaeacc733732442d1c9e734946d8','candidate':'a9ee073877dcb63434ab9282ce97b87cbdcbfe93ced24462bf198fccc85dcf6d','global':'294f6b5d02bd99f316b50a880a2e9376afcbcaeacc733732442d1c9e734946d8','original_collector':'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a','detail_collector':'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab'},pins
def unchanged_tree(path):
    tree=ast.parse(path.read_text(encoding='utf-8'))
    tree.body=[node for node in tree.body if not (isinstance(node,ast.FunctionDef) and node.name=='reviewed_sta_collector')]
    return ast.dump(tree,include_attributes=False)
assert unchanged_tree(baseline)==unchanged_tree(candidate), 'Other policy logic changed'
text=detail.read_text();lines=text.splitlines()
assert len(lines)<100
for line in lines:
    if line.lstrip().startswith('#'):continue
    assert not any(token in line.lower() for token in ['exec ','source ','quartus_asm','quartus_cpf','quartus_sh','execute_module','execute_flow','create_clock','set_clock_groups','set_false_path','set_multicycle_path']),line
for required in ['set matches [get_clocks $pattern]','get_clock_info -name','-from_clock $clock -to_clock $clock','project_close -dont_export_assignments','read_sdc','report_ucp','report_min_pulse_width']:
    assert required in text,required
qual=json.loads((root/'detail_qualification.json').read_text());prior=json.loads((root/'collector_qualification.json').read_text());old=json.loads((root/'qualification.json').read_text())
assert qual['pass'] and qual['total_checks']==204 and qual['new_cases']==len(qual['results'])==23
assert prior['pass'] and prior['total_checks']==181 and prior['new_cases']==len(prior['results'])==26
assert old['pass'] and old['checks']==len(old['results'])==155
assert qual['candidate_sha256']==pins['candidate'] and qual['baseline_sha256']==pins['baseline'] and qual['detail_collector_sha256']==pins['detail_collector']
b=load('detail_independent_baseline',baseline);g=load('detail_independent_candidate',candidate)
exe=r'D:/q17/quartus/bin64/quartus_sta.exe';project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N';destination=str(collector_root/'all-corners')
args=['-t',str(detail),project,'Alpha68k_N',destination]
quote=lambda x:"'"+x.replace("'","''")+"'"
command=lambda tool,a:'& '+quote(tool)+' '+' '.join(quote(x) for x in a)
results=[]
def case(name,tool,a,accepted,prior_accepted=False):
    cmd=command(tool,a)
    assert g.reviewed_sta_collector(tool,a)==accepted,(name,'predicate')
    out=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':cmd}},'codex','powershell',True)
    previous=b.adapt({'tool_name':'exec_command','tool_input':{'cmd':cmd}},'codex','powershell',True)
    if accepted:
        assert g.classify(tool,a)=='pass' and g.is_check_only(cmd,'powershell') and g.authorized_check_command(cmd,'powershell')
        assert out['hookSpecificOutput']['permissionDecision']=='allow' and 'updatedInput' not in out['hookSpecificOutput']
        if prior_accepted:assert out==previous
        else:assert previous['hookSpecificOutput']['permissionDecision']=='deny'
    else:assert out==previous,(name,out,previous)
    typed={'tool_name':'mcp__capsule__capsule','tool_input':{'action':'run','payload':{'command':cmd,'cwd':str(root)}}}
    assert g.adapt(typed,'codex','powershell',True)==b.adapt(typed,'codex','powershell',True)
    results.append({'name':name,'accepted':accepted,'command':cmd,'output':out})
case('detail_exact',exe,args,True)
case('detail_native_case',exe.upper(),[args[0],args[1].upper().replace('/','\\'),args[2].upper(),args[3],args[4].upper()],True)
old_args=args.copy();old_args[1]=str(original);case('original_exact_unchanged',exe,old_args,True,True)
for label,index,value in [('unknown_hash_same_root',1,str(collector_root/'other.tcl')),('outside_root',1,'D:/other/all-corners-detail.tcl'),('traversal_escape',1,str(collector_root/'../all-corners-detail.tcl')),('relative_collector',1,'all-corners-detail.tcl'),('collector_ads',1,str(detail)+':data'),('collector_nul',1,str(detail)+'\0'),('collector_lf',1,str(detail)+'\n'),('project_wrong',2,project+'2'),('project_escape',2,project+'/../../outside'),('revision_case',3,'alpha68k_n'),('revision_expression',3,'$(quartus_asm)'),('output_escape',4,destination+'/../../other'),('output_absolute_other',4,'D:/other'),('output_relative',4,'all-corners'),('flag_upper',0,'-T'),('flag_script',0,'--script'),('flag_eval',0,'--eval')]:
    changed=args.copy();changed[index]=value;case(label,exe,changed,False)
for tool in ['quartus_sta',exe.replace('bin64','bin'),exe.replace('D:','C:'),exe.replace('quartus_sta','quartus_sh'),exe.replace('quartus_sta','quartus_asm'),exe.replace('quartus_sta','quartus_cpf')]:case('wrongtool_'+tool,tool,args,False)
for extra in ['-t','--flow','compile','--allow-rbf','--eval','--script']:case('extra_'+extra,exe,args+[extra],False)
case('missing_output',exe,args[:-1],False)
for suffix in ['; quartus_asm x','\nquartus_asm x','\rquartus_asm x','\r\nquartus_asm x',' | Stop-Process -Name quartus_map',' & quartus_asm x',' > quartus.rbf',' && quartus_asm x']:
    cmd=command(exe,args)+suffix;event={'tool_name':'exec_command','tool_input':{'cmd':cmd}}
    out=g.adapt(event,'codex','powershell',True)
    assert out==b.adapt(event,'codex','powershell',True) and out['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':'compound_'+repr(suffix),'accepted':False,'command':cmd,'output':out})
for name,script,content,error in [('detail_changed',detail,detail.read_bytes()+b'\n',None),('original_changed',original,original.read_bytes()+b'\n',None),('detail_original_hash_swap',detail,original.read_bytes(),None),('original_detail_hash_swap',original,detail.read_bytes(),None),('exec_payload',detail,b'exec quartus_asm\n',None),('source_payload',detail,b'source other.tcl\n',None),('oversize',detail,b'x'*65537,None),('missing',detail,None,OSError('missing'))]:
    changed=args.copy();changed[1]=str(script)
    with patch.object(g,'open',create=True) as opened:
        if error:opened.side_effect=error
        else:opened.return_value.__enter__.return_value.read.return_value=content
        assert not g.reviewed_sta_collector(exe,changed)
        cmd=command(exe,changed)
        assert not g.is_check_only(cmd,'powershell') and not g.authorized_check_command(cmd,'powershell')
        out=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':cmd}},'codex','powershell',True)
        assert out['hookSpecificOutput']['permissionDecision']=='deny'
        results.append({'name':name,'accepted':False,'output':out})
encoded=base64.b64encode(command(exe,args).encode('utf-16-le')).decode()
for name,cmd in [('encoded_delegate','powershell -EncodedCommand '+encoded),('raw_flow',"& 'D:/q17/quartus/bin64/quartus_sh.exe' --flow compile Alpha68k_N"),('kill_quartus','Stop-Process -Name quartus_map'),('python_delegate',"python -c 'import subprocess; subprocess.run([\"quartus_asm\"])'")]:
    event={'tool_name':'exec_command','tool_input':{'cmd':cmd}}
    out=g.adapt(event,'codex','powershell',True)
    assert out==b.adapt(event,'codex','powershell',True) and out['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':name,'accepted':False,'command':cmd,'output':out})
receipt={'pass':True,'pins':pins,'unchanged_other_policy_ast':True,'detail_lines':len(lines),'builder_tests_checked':204,'independent_cases':len(results),'findings':[],'dangerous_commands_executed':False,'global_deployment':False,'scope':'Full guard diff and pinned detailed Tcl; pure predicate, classifier, check/approval callers and carriers. No Tcl or Quartus executed.','results':results}
(root/'independent_review_v1.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
