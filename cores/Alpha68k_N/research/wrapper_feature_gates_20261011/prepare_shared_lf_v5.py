import hashlib,json,pathlib,shutil,subprocess
R=pathlib.Path(__file__).resolve().parent; A=R/'unified_emu_admission_v4'; B=R/'unified_emu_admission_v5'
def sha(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def put(n,v):(B/n).write_text(json.dumps(v,indent=2)+'\n')
assert sha(A/'preparation_manifest.json')=='6f70cee82cd1e924c5b601acf3a89a391d6844ac6336ee28437a39fb97ebaabc'
assert json.loads((A/'native_build_exit.json').read_text())['actual_exit']==2
assert 'invalid option name' in (A/'native_build.stderr.log').read_text()
assert not (A/'linux_build_directory.txt').exists(),'precompiler failure scope contradicted'
assert not B.exists()
B.mkdir();m=json.loads((A/'preparation_manifest.json').read_text());unchanged=[]
for e in m['files']:
    p=pathlib.Path(e['path']);assert sha(p)==e['sha256'],str(p)
    q=B/p.relative_to(A);q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
    if q.name not in ['build.sh','commands.json']:unchanged.append({'path':str(q.relative_to(B)),'sha256':sha(q)})
recipe=(A/'build.sh').read_bytes();assert b'\r\n' in recipe
(B/'build.sh').write_bytes(recipe.replace(b'\r\n',b'\n'))
assert b'\r' not in (B/'build.sh').read_bytes()
c=json.loads((A/'commands.json').read_text());c=json.loads(json.dumps(c).replace(str(A).replace('\\','\\\\'),str(B).replace('\\','\\\\')));c['status']='Root approved LF-only recipe correction within ONE shared compilation and Japan1201 runtime; Stingray held';put('commands.json',c)
p=subprocess.run(['D:/vibes/fpga/toolchains/msys64/usr/bin/bash.exe','-n',str(B/'build.sh')],capture_output=True,text=True)
assert p.returncode==0,p.stderr
put('LF_only_supplement.json',{'parent_manifest':sha(A/'preparation_manifest.json'),'parent_actual_precompiler_exit':sha(A/'native_build_exit.json'),'precompiler_failure':'Bash set pipefail CRLF invalid option; no Linux snapshot created; Verilator never launched','parent_file_count':len(m['files']),'unchanged_parent_file_count':len(unchanged),'unchanged_files':unchanged,'only_mutations':['build.sh CRLF to LF, byte-exact after removing CR','commands paths rebased to isolated v5; root release status updated'],'old_recipe_sha256':sha(A/'build.sh'),'LF_recipe_sha256':sha(B/'build.sh'),'bash_syntax_actual_exit':p.returncode,'bash_syntax_stdout':p.stdout,'bash_syntax_stderr':p.stderr,'root_release':'Routine LF-only correction within prior approved single shared compiler/Japan scope; no additional release roundtrip required','no_compiler_runtime_yet':True})
files=[p for p in B.rglob('*') if p.is_file()]
put('preparation_manifest.json',{'scope':'Approved shared native source graph v4 plus LF-only Bash recipe supplement v5; no RTL/host/tail/audio changes','files':[{'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size} for p in sorted(files)],'generator':{'path':str(pathlib.Path(__file__)),'sha256':sha(__file__)}})
print(json.dumps({'manifest':sha(B/'preparation_manifest.json'),'recipe':sha(B/'build.sh'),'files_parent':len(m['files']),'unchanged':len(unchanged),'bash_n_exit':p.returncode}))
