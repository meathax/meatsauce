from pathlib import Path
import importlib.util, hashlib, json, base64, sys

root=Path(__file__).resolve().parent
deployed='--deployed' in sys.argv
candidate=Path(json.loads((root/'manifest.json').read_text())['original_path']) if deployed else root/'shared_quartus_queue_hook.py'
assert hashlib.sha256(candidate.read_bytes()).hexdigest()==json.loads((root/'manifest.json').read_text())['candidate_sha256']
spec=importlib.util.spec_from_file_location('guard_candidate',candidate)
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
fast=r'C:\Users\meath\QuartusFast\quartus-fast.ps1'
project=r'D:\Arcade\AI\aCORES\Alpha68k N\research\quartus_check_current_stage\Alpha68k_N.qpf'
def quote(value):return "'"+value.replace("'","''")+"'"
def cmd(args, exe=fast):return '& '+quote(exe)+' '+' '.join(quote(a) for a in args)
base=['build','--project',project,'--threads','2','--no-fallback']
cases=[]
def check(name,command,allowed):
    replacement,error=g.adapt_shell(command,'powershell',r'D:\Arcade\AI\aCORES\Alpha68k N')
    assert (error is None)==allowed,(name,error)
    assert replacement is None,(name,'unexpected replacement')
    event={'tool_name':'exec_command','tool_input':{'cmd':command,'workdir':r'D:\Arcade\AI\aCORES\Alpha68k N'}}
    result=g.adapt(event,'codex','powershell',True)
    assert (result=={})==allowed,(name,result)
    # Permitted classification never grants automatic approval or hides arguments.
    cases.append({'name':name,'permitted_to_normal_review':allowed,'replacement':replacement,'error':error,'hook_output':result})

for mode in ['dev-fast','dev-safe','release']:
    check('fixed_fast_'+mode,cmd(base+['--mode',mode]),True)
check('fixed_fast_full_visible_review',cmd(base+['--allow-rbf']),True)
check('fixed_fast_check_flag',cmd(base+['--checks-only']),True)
check('literal_PowerShell_file', '& powershell.exe -NoProfile -File '+quote(fast)+' '+' '.join(quote(a) for a in base),True)
for label,args in [
    ('unknown_flag',base+['--eval','quartus_asm']),
    ('duplicate_project',base+['--project',project]),
    ('missing_project',['build']),
    ('relative_project',['build','--project','file.qpf']),
    ('wrong_extension',['build','--project',r'D:\file.tcl']),
    ('invalid_threads',base[:-3]+['--threads','0']),
    ('unknown_mode',base+['--mode','unchecked']),
    ('conflicting_assembly',base+['--checks-only','--allow-rbf']),
    ('recipe_delegate',['run','--recipe','unknown']),
]:check(label,cmd(args),False)
check('noncanonical_fast',cmd(base,r'D:\copy\quartus-fast.ps1'),False)
check('shell_chain',cmd(base)+'; quartus_asm Alpha68k_N',False)
check('dynamic_project', '& '+quote(fast)+' build --project $project',False)
check('raw_asm','& '+quote(r'D:\q17\quartus\bin64\quartus_asm.exe')+' Alpha68k_N',False)
check('raw_cpf','& '+quote(r'D:\q17\quartus\bin64\quartus_cpf.exe')+' -c file.sof file.rbf',False)
check('raw_full_compile','& '+quote(r'D:\q17\quartus\bin64\quartus_sh.exe')+' --flow compile Alpha68k_N',False)
check('direct_worker','& '+quote(g.WORKER)+' -Action Start',False)
check('queue_namespace','& '+quote(g.FLOW)+r' -Action Start -GlobalSlotRoot D:\other',False)
check('separate_queue_fit','& '+quote(g.FLOW)+' -Action Start -Stage fit',False)
check('canonical_compile_visible', '& '+quote(g.FLOW)+' -Action Start -Stage compile',True)
check('check_direct', '& '+quote(r'D:\q17\quartus\bin64\quartus_fit.exe')+' Alpha68k_N',True)
encoded=base64.b64encode(cmd(base).encode('utf-16-le')).decode()
check('encoded_fast','powershell.exe -EncodedCommand '+encoded,False)
check('name_kill','Stop-Process -Name quartus*',False)
check('comment_tool_powershell','powershell -Command "& (\'quartus\'+\'_asm\') \'p\'; # quartus_map"',False)
check('comment_tool_python', 'python -c '+quote("import subprocess; subprocess.run(['quartus'+'_asm','p']); # quartus_map"),False)
check('raw_script_equals', '& '+quote(r'D:\q17\quartus\bin64\quartus_map.exe')+' --script=foo',False)
check('raw_eval_equals', '& '+quote(r'D:\q17\quartus\bin64\quartus_sta.exe')+' --eval=foo',False)
check('flow_fast_assembly_delegate', '& '+quote(g.FLOW)+' -Action Start -QuartusFast -AllowRbf',False)
for flag in ['-t','-s','--tcl_eval','--tcl-eval','--shell']:
    for suffix in [' delegate.tcl','=delegate.tcl']:
        check('raw_delegate_'+flag+suffix, '& '+quote(r'D:\q17\quartus\bin64\quartus_sta.exe')+' '+flag+suffix,False)
check('queue_colon_namespace', '& '+quote(g.FLOW)+r' -Action Start -GlobalSlotRoot:D:\other',False)
check('queue_abbreviated_namespace', '& '+quote(g.FLOW)+r' -Action Start -GlobalSl D:\other',False)
check('queue_abbreviated_fit', '& '+quote(g.FLOW)+' -Act Start -Sta fit',False)
check('queue_colon_fit', '& '+quote(g.FLOW)+' -Action:Start -Stage:fit',False)
check('queue_colon_conversion', '& '+quote(g.FLOW)+' -Action:ConvertRbf',False)
check('queue_abbreviated_compile', '& '+quote(g.FLOW)+' -Act Start -Sta compile',True)
check('flow_abbreviated_fast', '& '+quote(g.FLOW)+' -Action Start -QuartusF -AllowRbf',False)

read_code="from pathlib import Path; root=Path(r'D:\\Arcade\\AI\\aCORES\\Alpha68k N'); lines=(root/'AGENTS.md').read_text(encoding='utf-8').splitlines(); print('\\n'.join(lines[:22])); print('Quartus');\nfor index,line in enumerate(lines):\n if 'Quartus' in line or 'agent' in line: print(index,line)\nfor p in [Path(r'D:\\Arcade\\AI\\aCORES\\Alpha68k N\\quartus_hold.json'),Path(r'D:\\Arcade\\AI\\aCORES\\meatsauce-alpha68kn\\cores\\Alpha68k_N\\quartus_hold.json')]:\n if p.exists(): print(p.read_text())"
def py(code):return 'python -X utf8 -c '+quote(code)
check('readonly_Path_evidence',py(read_code),True)
exact_root="from pathlib import Path; p=Path(r'D:\\Arcade\\AI\\aCORES\\Alpha68k N'); f=p/'AGENTS.md'; lines=f.read_text(encoding='utf-8').splitlines(); print('\\n'.join(str(i+1)+':'+l[:750] for i,l in enumerate(lines) if i<22 or 'Quartus' in l or 'agent' in l)); print('HOLD CONFIGS'); [(print(str(q)),print(q.read_text(encoding='utf-8')[:2000])) for b in [p,Path(r'D:\\Arcade\\AI\\aCORES\\meatsauce-alpha68kn\\cores\\Alpha68k_N')] for q in [b/'quartus_hold.json'] if q.exists()]"
check('readonly_exact_root_singlequoted',py(exact_root),True)
check('readonly_exact_root_doublequoted','python -X utf8 -c "'+exact_root+'"',True)
check('readonly_Quartus_literal',py("print('Quartus')"),True)
check('readonly_quartus_artifact_literal',py("print('quartus_check_current_stage')"),True)
for name,code in [
 ('subprocess_delegate',"import subprocess; subprocess.run(['quartus_asm','x'])"),
 ('os_delegate',"import os; os.system('quartus_sh --flow compile x')"),
 ('eval_delegate',"eval(\"__import__('os').system('quartus_asm x')\")"),
 ('exec_delegate',"exec(\"import os; os.system('quartus_asm x')\")"),
 ('Path_write',"from pathlib import Path; Path(r'D:\\quartus_guard.txt').write_text('x')"),
 ('builtin_shadow',"print=__import__('os').system; print('quartus_asm x')"),
 ('Path_shadow',"from pathlib import Path; Path=lambda x: __import__('os').system(x); Path('quartus_asm x')"),
 ('dunder_traversal',"from pathlib import Path; print(Path.__class__); print('quartus_asm')"),
 ('dynamic_Path',"from pathlib import Path; p='D:\\quartus_guard.txt'; print(Path(p).read_text())"),
 ('file_print',"from pathlib import Path; print('quartus_check',file=Path(r'D:\\x'))"),
 ('function_def',"def run(): pass\nprint('quartus_check')"),
 ('generator_exec',"print(''.join(str(eval(x)) for x in ['quartus_asm']))"),
 ('comprehension_write',"from pathlib import Path; [p.write_text('x') for p in [Path(r'D:\\quartus_guard.txt')]]"),
 ('comprehension_subprocess',"import subprocess; [subprocess.run(['quartus_asm','x']) for x in ['a']]"),
]:check(name,py(code),False)

# No source, queue, tool or environment state is mutated by these classification tests.
original=root/'shared_quartus_queue_hook.original.py'
receipt={'status':'pass','cases':len(cases),'original_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),'candidate_sha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),'tests_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'results':cases,'limits':'AST grammar classifies source only; Python runtime/startup/std-library environment remains subject to normal execution review. No permission allow result; full --allow-rbf remains visible and separately gated.'}
receipt['loaded_path']=str(candidate)
(root/('deployed_classification_receipt.json' if deployed else 'test_receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':'pass','cases':len(cases),'candidate_sha256':receipt['candidate_sha256']}))
