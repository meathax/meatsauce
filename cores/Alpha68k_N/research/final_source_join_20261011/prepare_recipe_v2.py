from pathlib import Path
import hashlib,json,re,shlex,difflib,shutil
ROOT=Path(__file__).resolve().parent;SRC=ROOT/'candidate';DEST=ROOT/'candidate_v2'
GAME=Path('D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_gameplay181')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def save(p,obj):p.write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8')
def write(p,text):p.write_text(text,encoding='utf-8',newline='\n')
assert sha(ROOT/'import_manifest.json')=='b62087cbe7bea7854255ff3c3d6f5bc491c8cbcd1571d9117fc936be45b8e152'
assert not DEST.exists(),'Immutable candidate_v2 already exists; do not overwrite.'
recipe=GAME/'source/sim/build_system.sh';reference=recipe.read_text()
assert json.loads((GAME/'build_exit.json').read_bytes())['exit_code']==0
protocol=GAME/'protocol_verification_v3.json';obj=json.loads(protocol.read_bytes());assert obj['protocol_source_pass'];assert obj['checks']['compiled_real_CPU_graph_hashes_exact']
new=reference.replace('sim/coupled_observer.vlt ','').replace(' coupled_observer.vlt ',' ')
assert 'coupled_observer.vlt' not in new
original=(SRC/'sim/build_system.sh').read_text()
expected=original.replace('    sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256','    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256').replace('rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv \\\n','rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv rtl/alpha68kn_mcu.sv \\\n').replace('    sim/system_main.cpp sim/sdram_model.h "$build_root/"','    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h "$build_root/"').replace('alpha68kn_system.sv alpha68kn_audio.sv alpha68kn_soundchips.sv alpha68kn_mixer.sv \\\n','alpha68kn_system.sv alpha68kn_audio.sv alpha68kn_soundchips.sv alpha68kn_mixer.sv alpha68kn_mcu.sv \\\n')
assert new==expected, 'Unreviewed recipe change beyond dependency closure.'
shutil.copytree(SRC,DEST,ignore=shutil.ignore_patterns('coupled_observer.vlt'))
write(DEST/'sim/build_system.sh',new)
changed=[]
for p in sorted(DEST.rglob('*')):
 if not p.is_file():continue
 rel=p.relative_to(DEST);old=SRC/rel
 assert old.exists()
 if p.read_bytes()!=old.read_bytes():changed.append(rel.as_posix())
assert changed==['sim/build_system.sh']
assert not (DEST/'sim/coupled_observer.vlt').exists()
logical=new.replace('\\\n',' ')
lines=logical.splitlines();hashline=next(s for s in lines if s.startswith('sha256sum '));copyline=next(s for s in lines if s.startswith('cp rtl/alpha68kn_board.sv '));compileline=next(s for s in lines if s.startswith('/usr/local/bin/verilator --cc '))
def expand(patterns):
 out=[]
 for pat in patterns:
  matches=list(DEST.glob(pat)) if '*' in pat else [DEST/pat]
  assert matches and all(p.exists() for p in matches),('Missing source pattern',pat)
  out+=matches
 return out
hashpatterns=shlex.split(hashline)[1:];hashpatterns=hashpatterns[:hashpatterns.index('>')]
hashinputs=expand(hashpatterns)
copytokens=shlex.split(copyline)[1:];assert copytokens[-1]=='$build_root/';copyinputs=expand(copytokens[:-1]);byname={p.name:p for p in copyinputs};assert len(byname)==len(copyinputs),'Flattened source collision'
args=shlex.split(compileline);compileinputs=[]
for name in args:
 if name=='./*.v':compileinputs += [p for p in copyinputs if p.suffix=='.v']
 elif name.endswith('.sv'):compileinputs.append(byname[name])
 elif name=='$build_root/system_main.cpp':compileinputs.append(byname['system_main.cpp'])
assert len({p.name for p in compileinputs})==len(compileinputs)
compiledHDL=[p for p in compileinputs if p.suffix in {'.sv','.v'}]
assert any(p.name=='alpha68kn_mcu.sv' for p in compiledHDL)
assert any(p.name=='t48_core.v' for p in compiledHDL)
assert all(p in hashinputs for p in compileinputs+[byname['sdram_model.h']])
refHDL={n:h for n,h in obj['compiled_hashes'].items() if Path(n).suffix in {'.sv','.v'}}
assert {p.name for p in compiledHDL}==set(refHDL)
hash_differences=[{'name':p.name,'reference_sha256':refHDL[p.name],'proposal_sha256':sha(p)} for p in compiledHDL if sha(p)!=refHDL[p.name]]
assert [x['name'] for x in hash_differences]==['alpha68kn_board.sv'],'Unexpected actual compiled HDL drift'
assert "sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;" in (DEST/'rtl/alpha68kn_board.sv').read_text()
v2proof={'scope':'Static native recipe qualification only; no new native build/run.','original_proposal_manifest':pin(ROOT/'import_manifest.json'),'actual_reference_recipe':pin(recipe),'actual_reference_build_exit':pin(GAME/'build_exit.json'),'actual_reference_protocol':pin(protocol),'actual_reference_manifest':pin(GAME/'import_manifest.json'),'minimal_recipe_changed_files':changed,'omitted_optional_readonly_config':'sim/coupled_observer.vlt; standard canonical host retained','unchanged_functional_HDL':True,'compiled_HDL_count':len(compiledHDL),'same_actual_reference_HDL_filenames':True,'reference_compiled_hash_differences':hash_differences,'compile_input_pins':[pin(p) for p in compileinputs],'hash_receipt_inputs':[pin(p) for p in hashinputs],'all_compiled_inputs_and_host_header_in_sha256_receipt':True,'MCU_copy_compile_hash':True,'T48_copy_compile_hash':True,'new_native_build_or_replay':False,'root_release_required':True}
save(ROOT/'recipe_v2_static_verification.json',v2proof)
write(ROOT/'recipe_v2_supplement.patch',''.join(difflib.unified_diff(original.splitlines(True),new.splitlines(True),fromfile='a/sim/build_system.sh',tofile='b/sim/build_system.sh')))
save(ROOT/'candidate_v2_source_closure.json',{'scope':'Immutable proposed source graph; no compiled ELF identity.','files':[pin(p) for p in sorted(DEST.rglob('*')) if p.is_file()],'unchanged_functional_HDL':True,'omitted_optional_config':'sim/coupled_observer.vlt'})
manifestfiles=[p for p in sorted(DEST.rglob('*')) if p.is_file()]+[ROOT/'prepare_recipe_v2.py',ROOT/'recipe_v2_static_verification.json',ROOT/'recipe_v2_supplement.patch',ROOT/'candidate_v2_source_closure.json',ROOT/'conditional_profile2_enable.patch']
save(ROOT/'recipe_v2_import_manifest.json',{'scope':'Supplement to b620 proposal: minimum native harness dependency closure fix. No HDL/production changes/build/replay.','original_manifest':pin(ROOT/'import_manifest.json'),'files':[pin(p) for p in manifestfiles]})
host=(DEST/'sim/system_main.cpp').read_text()
hostgates=[{'line':i+1,'text':line.strip()} for i,line in enumerate(host.splitlines()) if ('profile' in line.lower() or 'header[5]' in line) and any(t in line for t in ['>','throw','runtime_error'])]
print(json.dumps({'actual_exit_code':0,'changed_files':changed,'candidate_v2':str(DEST),'manifest':pin(ROOT/'recipe_v2_import_manifest.json'),'static_proof':pin(ROOT/'recipe_v2_static_verification.json'),'compiled_HDL_count':len(compiledHDL),'ref_filename_set_exact':True,'functional_HDL_unchanged':True,'native_build_or_replay':False,'host_profile_gate_review':hostgates},indent=2))
