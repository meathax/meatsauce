"""Prepare only: exact graph pins, candidate guard, explicit baseline equivalence. No tool launch."""
from pathlib import Path
import hashlib,json,shutil,re,datetime
base=Path(__file__).resolve().parent
canonical=Path(r'D:\Arcade\AI\aCORES\meatsauce-alpha68kn\cores\Alpha68k_N')
launch=json.loads((base/'complete_overlay_launch.json').read_text(encoding='utf-8-sig'))
result=json.loads(Path(r'C:\Users\meath\QuartusFast\runs\20261010-193713-46508-dev-fast\result.json').read_text(encoding='utf-8-sig'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert len(launch['canonical_source_pins'])==161
for name,digest in launch['canonical_source_pins'].items(): assert sha(canonical/name)==digest,name
baseline=base.parent/'board15_complete_check'
assert sha(baseline/'alpha68kn_board.sv')=='3bbf5c3719801a26a962d78a579dafbf92950c9929d60fa73b53a4931063440a'
source=(baseline/'alpha68kn_board.sv').read_text()
line='            2:debug_rom_data<={sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};'
assert source.count(line)==1
replacement='`ifdef VERILATOR\n'+line+'\n`endif'
candidate=source.replace(line,replacement)
assert candidate.replace(replacement,line)==source
assert '.debug_rom_kind(4\'d0)' in (canonical/'Alpha68k_N.sv').read_text().replace(' ','')
out=base/'case2_full_map'
out.mkdir(exist_ok=True)
board=out/'alpha68kn_board.sv'
board.write_text(candidate,encoding='utf-8',newline='\r\n')
shutil.copyfile(baseline/'Alpha68k_N.qpf',out/'Alpha68k_N.qpf')
qsf=(baseline/'Alpha68k_N.qsf').read_text()
assert 'PRE_FLOW_SCRIPT_FILE' not in qsf
old=(baseline/'alpha68kn_board.sv').as_posix()
assert qsf.count(old)==1
qsf=qsf.replace(old,board.as_posix())
assert result['settings']=={'FITTER_EFFORT':'FAST FIT','SYNTHESIS_EFFORT':'FAST','PHYSICAL_SYNTHESIS_EFFORT':'FAST','NUM_PARALLEL_PROCESSORS':2}
settings={**result['settings'],'GENERATE_RBF_FILE':'OFF'}
for key,value in settings.items():
    qsf=re.sub(r'^set_global_assignment -name '+key+r' .+\n','',qsf,flags=re.M)
    qsf+=f'set_global_assignment -name {key} "{value}"\n'
(out/'Alpha68k_N.qsf').write_text(qsf,encoding='utf-8',newline='\r\n')
for name in ['build_id.v','microrom.mem','nanorom.mem']: shutil.copyfile(canonical/name,out/name)
meta={'status':'prepared_NOT_launched','utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baseline_run':result['run'],'baseline_map_exit':result['steps']['map']['exit_code'],'baseline_map_command':['D:/q17/quartus/bin64/quartus_map.exe','Alpha68k_N','-c','Alpha68k_N','--read_settings_files=on','--write_settings_files=off'],'canonical_source_pins':launch['canonical_source_pins'],'candidate_board_sha256':sha(board),'baseline_board_sha256':sha(baseline/'alpha68kn_board.sv'),'verilator_guard_exact_removal_identity':True,'physical_top_kind_zero':True,'qsf_sha256':sha(out/'Alpha68k_N.qsf'),'baseline_recorded_settings':result['settings'],'effective_baseline_qsf_equivalence':'PENDING actual Fast workdir QSF comparison; no launch authorized by this preparation','rbf':False,'fit':False}
(out/'prepared.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps({k:v for k,v in meta.items() if k!='canonical_source_pins'}))
