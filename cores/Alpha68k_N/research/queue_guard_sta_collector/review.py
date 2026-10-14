from pathlib import Path
import hashlib, importlib.util, json, subprocess, sys
from unittest.mock import patch

root=Path(__file__).parent
if '--worker' not in sys.argv:
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'review.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'dangerous_commands_executed':False}
    (root/'review_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr)
    sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('review_sta_baseline',root/'baseline.py');g=load('review_sta_candidate',root/'candidate.py')
global_path=Path(r'C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_queue_hook.py')
collector=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners.tcl')
project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
destination=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
exe=r'D:/q17/quartus/bin64/quartus_sta.exe'
args=['-t',str(collector),project,'Alpha68k_N',destination]
pins={'baseline':sha(root/'baseline.py'),'candidate':sha(root/'candidate.py'),'global':sha(global_path),'collector':sha(collector)}
assert pins=={'baseline':'afcf3db289db892de176c233b411a267d1c687012e1334988a83ffd8b3efbf04','candidate':'294f6b5d02bd99f316b50a880a2e9376afcbcaeacc733732442d1c9e734946d8','global':'afcf3db289db892de176c233b411a267d1c687012e1334988a83ffd8b3efbf04','collector':'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a'},pins
lines=collector.read_text().splitlines()
assert 45<=len(lines)<=55
for line in lines:
    if line.lstrip().startswith('#'):continue
    assert not any(token in line.lower() for token in ['exec ','source ','quartus_asm','quartus_cpf','quartus_sh','execute_module','execute_flow']),line
assert 'project_open -revision $revision $project' in lines
assert 'read_sdc' in lines and 'create_timing_netlist' in lines
q=json.loads((root/'collector_qualification.json').read_text())
prior=json.loads((root/'qualification.json').read_text())
assert q['pass'] and prior['pass'] and q['total_checks']==181 and q['new_cases']==len(q['results'])==26
assert prior['checks']==len(prior['results'])==155 and q['prior155_pass']
assert q['candidate_sha256']==pins['candidate'] and q['baseline_sha256']==pins['baseline'] and q['collector_sha256']==pins['collector']

quote=lambda x:"'"+x.replace("'","''")+"'"
command=lambda tool,a:'& '+quote(tool)+' '+' '.join(quote(x) for x in a)
results=[]
def run_case(name,tool,a,accepted):
    cmd=command(tool,a)
    assert g.reviewed_sta_collector(tool,a)==accepted,(name,'predicate')
    outputs={}
    for shell in ['powershell']:
        event={'tool_name':'exec_command','tool_input':{'cmd':cmd,'workdir':str(root)}}
        output=g.adapt(event,'codex',shell,True);old=b.adapt(event,'codex',shell,True)
        if accepted:
            assert g.classify(tool,a)=='pass'
            assert g.is_check_only(cmd,shell) and g.authorized_check_command(cmd,shell)
            assert output['hookSpecificOutput']['permissionDecision']=='allow' and 'updatedInput' not in output['hookSpecificOutput']
            assert old['hookSpecificOutput']['permissionDecision']=='deny'
        else:assert output==old,(name,output,old)
        outputs[shell]=output
    # Typed Capsule execution remains refused even for the exact collector;
    # this change grants no execution forwarding to an unknown carrier.
    event={'tool_name':'mcp__capsule__capsule','tool_input':{'action':'run','payload':{'command':cmd,'cwd':str(root)}}}
    output=g.adapt(event,'codex','powershell',True)
    assert output==b.adapt(event,'codex','powershell',True)
    assert output['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':name,'accepted':accepted,'command':cmd,'outputs':outputs})
run_case('exact',exe,args,True)
run_case('upper_windows_path_spellings',exe.upper(),[args[0],args[1].upper(),args[2].upper(),args[3],args[4].upper()],True)
equivalent=args.copy();equivalent[2]=project+'/../Alpha68k_N';run_case('same_normalized_project',exe,equivalent,True)
for name,index,value in [
    ('wrong_revision_case',3,'alpha68k_n'),('revision_command',3,'Alpha68k_N; quartus_asm'),
    ('collector_same_name_other_root',1,'D:/other/all-corners.tcl'),('collector_escape',1,str(collector.parent)+'/../all-corners.tcl'),
    ('project_escape',2,project+'/../outside'),('output_escape',4,destination+'/../../outside'),
    ('output_relative_drive',4,'D:all-corners'),('collector_unc',1,'//localhost/D$/'+str(collector)[3:]),
    ('output_env',4,'$env:quartus'),('revision_dollar',3,'$quartus'),('flag_case',0,'-T'),
    ('flag_long',0,'--script'),('flag_eval',0,'--tcl_eval'),('flag_equals',0,'-t='+str(collector)),
    ('collector_quote_data',1,str(collector)+"'; quartus_asm; '"),('collector_nul',1,str(collector)+'\0'),
    ('collector_newline',1,str(collector)+'\n'),('project_semicolon',2,project+'; quartus_asm'),
]:
    changed=args.copy();changed[index]=value;run_case(name,exe,changed,False)
for tool in ['quartus_sta',exe.replace('bin64','bin'),exe.replace('D:','C:'),exe.replace('quartus_sta','quartus_sh'),exe.replace('quartus_sta','quartus_asm'),exe.replace('quartus_sta','quartus_cpf')]:run_case('tool_'+tool,tool,args,False)
for extra in ['--flow','compile','--allow-rbf','-t','--script','--eval','quartus_asm']:
    run_case('extra_'+extra,exe,args+[extra],False)
for removed in range(5):run_case('missing_'+str(removed),exe,args[:removed]+args[removed+1:],False)
for suffix in ['; quartus_asm x','\nquartus_asm x','\rquartus_asm x','\r\nquartus_asm x',' | quartus_asm x',' && quartus_asm x',' > quartus.rbf',' & quartus_asm x']:
    cmd=command(exe,args)+suffix
    event={'tool_name':'exec_command','tool_input':{'cmd':cmd}}
    out=g.adapt(event,'codex','powershell',True)
    assert out==b.adapt(event,'codex','powershell',True) and out['hookSpecificOutput']['permissionDecision']=='deny'
    results.append({'name':'compound_'+repr(suffix),'accepted':False,'command':cmd,'output':out})
original=collector.read_bytes()
for name,content,error in [('changed_byte',original+b'\n',None),('evil_exec',b'exec quartus_asm\n',None),('evil_source',b'source other.tcl\n',None),('oversize',b'x'*65537,None),('missing',None,OSError('missing'))]:
    with patch.object(g,'open',create=True) as mocked:
        if error:mocked.side_effect=error
        else:mocked.return_value.__enter__.return_value.read.return_value=content
        assert not g.reviewed_sta_collector(exe,args)
        cmd=command(exe,args)
        assert not g.is_check_only(cmd,'powershell') and not g.authorized_check_command(cmd,'powershell')
        out=g.adapt({'tool_name':'exec_command','tool_input':{'cmd':cmd}},'codex','powershell',True)
        assert out['hookSpecificOutput']['permissionDecision']=='deny'
        results.append({'name':name,'accepted':False,'output':out})
receipt={'pass':True,'pins':pins,'collector_lines':len(lines),'independent_cases':len(results),'builder_checks_verified':181,'dangerous_commands_executed':False,'global_deployment':False,'findings':[],'results':results}
(root/'review.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='results'}))
