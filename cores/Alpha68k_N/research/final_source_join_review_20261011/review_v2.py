from pathlib import Path
import hashlib,json,shlex,subprocess,sys

root=Path(__file__).parent
proposal=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/final_source_join_20261011')
old=proposal/'candidate';candidate=proposal/'candidate_v2'
reference=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_gameplay181/source')
if '--worker' not in sys.argv:
    assert not (root/'review_v2_exit.json').exists(),'Immutable output exists'
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'review_v2.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'scope':'Read-only corrected source/dependency review; no native RTL build, replay or Quartus.'}
    (root/'review_v2_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr);sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
old_manifest=proposal/'import_manifest.json'
assert sha(old_manifest)=='b62087cbe7bea7854255ff3c3d6f5bc491c8cbcd1571d9117fc936be45b8e152'
manifest=proposal/'recipe_v2_import_manifest.json'
assert sha(manifest)=='029088a70ad03611730d0ad0b9f6c4db9ad53a867859ed5f8ca4f3b29f82427b'
entries=json.loads(manifest.read_text())['files']
for entry in entries:
    path=Path(entry['path']);assert path.stat().st_size==entry['bytes'] and sha(path)==entry['sha256'],path
prior=json.loads((root/'review_v1.json').read_text())
assert prior['review_completed'] and not prior['approved_for_merge'] and len(prior['findings'])==1
assert json.loads((root/'review_v1_exit.json').read_text())['actual_exit_code']==0
assert not (candidate/'sim/coupled_observer.vlt').exists()
checked=[]
for path in old.rglob('*'):
    if not path.is_file():continue
    relative=path.relative_to(old)
    if relative.as_posix() in ['sim/build_system.sh','sim/coupled_observer.vlt']:continue
    assert path.read_bytes()==(candidate/relative).read_bytes(),relative
    checked.append(relative.as_posix())
old_recipe=(old/'sim/build_system.sh').read_text();new_recipe=(candidate/'sim/build_system.sh').read_text()
expected=old_recipe.replace('    sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256','    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h > sim/build/system_inputs.sha256')
expected=expected.replace('rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv \\','rtl/alpha68kn_system.sv rtl/alpha68kn_audio.sv rtl/alpha68kn_mcu.sv \\')
expected=expected.replace('    sim/system_main.cpp sim/sdram_model.h "$build_root/"','    rtl/vendor/t48/t48_core.v sim/system_main.cpp sim/sdram_model.h "$build_root/"')
expected=expected.replace('alpha68kn_soundchips.sv alpha68kn_mixer.sv \\','alpha68kn_soundchips.sv alpha68kn_mixer.sv alpha68kn_mcu.sv \\')
assert new_recipe==expected,'Correction differs from four minimal dependency edits'
private_recipe=(reference/'sim/build_system.sh').read_text()
assert new_recipe==private_recipe.replace('sim/coupled_observer.vlt ','').replace('coupled_observer.vlt ',''),'Recipe differs beyond private observer removal'
logical=new_recipe.replace('\\\n','')
copy=next(line for line in logical.splitlines() if line.startswith('cp rtl/alpha68kn_board.sv'))
inputs=shlex.split(copy)[1:-1]
copied={}
for pattern in inputs:
    for path in candidate.glob(pattern):
        assert path.name not in copied,(path.name,'basename collision')
        copied[path.name]=path
assert 'alpha68kn_mcu.sv' in copied and 't48_core.v' in copied
verilator=next(line for line in logical.splitlines() if line.startswith('/usr/local/bin/verilator --cc'))
arguments=shlex.split(verilator)
assert 'alpha68kn_mcu.sv' in arguments and './*.v' in arguments
hdl={name:path for name,path in copied.items() if path.suffix=='.v' or (path.suffix=='.sv' and name in arguments)}
assert len(hdl)==67,len(hdl)
hash_line=next(line for line in logical.splitlines() if line.startswith('sha256sum '))
hash_patterns=shlex.split(hash_line.split(' > ')[0])[1:]
hashed={path for pattern in hash_patterns for path in candidate.glob(pattern)}
assert set(hdl.values()).issubset(hashed)
assert copied['system_main.cpp'] in hashed and copied['sdram_model.h'] in hashed
differences=[]
for name,path in hdl.items():
    reference_path=reference/path.relative_to(candidate)
    if sha(path)!=sha(reference_path):differences.append(path.relative_to(candidate).as_posix())
assert differences==['rtl/alpha68kn_board.sv'],differences
line='            2:debug_rom_data<={sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};'
private_board=(reference/'rtl/alpha68kn_board.sv').read_text();joined_board=(candidate/'rtl/alpha68kn_board.sv').read_text()
assert private_board.count(line)==1
assert joined_board==private_board.replace(line,'`ifdef VERILATOR\n'+line+'\n`endif')
receipt={'review_completed':True,'approved_for_bounded_merge':True,'findings':[],'resolved_prior_P1':'Native recipe now copies/compiles MCU, copies T48 into flattened Verilog closure, and hashes T48.','manifest_sha256':sha(manifest),'manifest_files_verified':len(entries),'prior_manifest_preserved_sha256':sha(old_manifest),'unchanged_candidate_files':len(checked),'corrected_recipe_sha256':sha(candidate/'sim/build_system.sh'),'compiled_HDL_files_modelled':len(hdl),'all_compiled_HDL_host_header_covered_by_hash_receipt':True,'same_successful_private_recipe_except_observer_config':True,'HDL_differences_from_private_graph':differences,'difference_scope':'Only existing sound diagnostic case2 VERILATOR guard; enabled body exact.','board_sha256':sha(candidate/'rtl/alpha68kn_board.sv'),'conditional_profile2_gate':'Retain <=1 until genuine181/realHPS wrapper gates; profile2 admission patch separate.','remaining_gates':['Shared SSG correction and all profiles need current-source replay binding.','Complete changed design needs all resource limits and all-corner timing/constraints acceptance.'],'builds_replays_Quartus':False}
(root/'review_v2.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps(receipt))
