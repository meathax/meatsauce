"""Append-only fit receipt; validate immutable MAP inputs and preserve reader observations."""
from pathlib import Path
import json,hashlib,shutil,datetime,subprocess
base=Path(__file__).resolve().parent
out=base/'case2_full_map'
dest=base/'case2_fit_sta'
dest.mkdir(exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
meta=json.loads((out/'prepared.json').read_text())
assert all(sha(out/'source'/name)==digest for name,digest in meta['canonical_source_pins'].items())
assert sha(out/'alpha68kn_board.sv')==meta['candidate_board_sha256']
assert sha(out/'Alpha68k_N.qsf')==meta['qsf_sha256']
launch={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'session_id':25928,'actual_launch_chunk':'ee65b1','cwd':str(out),'argv':['D:/q17/quartus/bin64/quartus_fit.exe',out.as_posix()+'/Alpha68k_N','-c','Alpha68k_N','--read_settings_files=on','--write_settings_files=off'],'reuse_native_MAP_DB':True,'source_pins_161_verified':True,'qsf_sha256':meta['qsf_sha256'],'board_sha256':meta['candidate_board_sha256'],'GENERATE_RBF_FILE':'OFF','production_queue':False,'RBF':False}
(dest/'fit_launch.json').write_text(json.dumps(launch,indent=2)+'\n')
# A follow-up read inadvertently overwrote the original read receipt; restore only if byte-exact original hash matches.
original_path=base/'owned_jobs_observation.json'
shutil.copyfile(original_path,dest/'pre_fit_owned_jobs_observation.json')
expected=next(row['sha256'] for row in json.loads((base/'case2_import_manifest.json').read_text())['files'] if row['path']=='owned_jobs_observation.json')
command='"D:\\vibes\\fpga\\toolchains\\msys64\\ucrt64\\bin\\python.exe" "D:\\Arcade\\AI\\aCORES\\Alpha68k N\\research\\sound_write_width\\inspect_owned_jobs.py"'
stdout=json.dumps({'ProcessId':33456,'ParentProcessId':33172,'CommandLine':command},separators=(',',':'))+'\n'
restored=(json.dumps({'exit':0,'stdout':stdout,'stderr':''},indent=2)+'\n').encode()
restore_match=hashlib.sha256(restored).hexdigest()==expected
if restore_match: original_path.write_bytes(restored)
receipt={'expected_original_sha256':expected,'candidate_reconstruction_sha256':hashlib.sha256(restored).hexdigest(),'reconstructed_from_original_tool_output':True,'restored_only_if_exact_hash_match':restore_match,'overwritten_observation_preserved':str(dest/'pre_fit_owned_jobs_observation.json')}
(dest/'reader_receipt_recovery.json').write_text(json.dumps(receipt,indent=2)+'\n')
for name in ['reports.tcl','all-corners.tcl']:
    shutil.copyfile(Path(r'C:\Users\meath\QuartusFast')/name,dest/name)
print(json.dumps({'fit_session_id':25928,'pins_verified':161,'recovery':receipt,'helpers':[{'path':str(dest/name),'sha256':sha(dest/name)} for name in ['reports.tcl','all-corners.tcl']]}))
