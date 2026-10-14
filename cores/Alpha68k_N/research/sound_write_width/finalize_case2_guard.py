"""Preserve terminal native MAP result; no fitter or assembler invocation."""
from pathlib import Path
import json,hashlib,sys,re,datetime
base=Path(__file__).resolve().parent
out=base/'case2_full_map'
meta=json.loads((out/'prepared.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
rc=int(sys.argv[1]); chunk=sys.argv[2]
rpt=out/'output_files/Alpha68k_N.map.rpt'
summary=out/'output_files/Alpha68k_N.map.summary'
assert rpt.exists() and summary.exists()
text=rpt.read_text(encoding='utf-8-sig',errors='replace')
pins_ok=all(sha(out/'source'/name)==digest for name,digest in meta['canonical_source_pins'].items())
assert pins_ok
assert sha(out/'alpha68kn_board.sv')==meta['candidate_board_sha256']
assert sha(out/'Alpha68k_N.qsf')==meta['qsf_sha256']
sound_lines=[line for line in text.splitlines() if 'sound_rom' in line.lower()]
metrics=[line for line in text.splitlines() if any(word in line for word in ['Total registers','Total combinational functions','Estimated ALM','Total block memory bits','Total logic cells','Total RAM','DSP block'])]
record={'status':'native_MAP_terminal','utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'actual_exit_code':rc,'actual_tool_chunk':chunk,'native_session_id':65792,'source_pins_161_unchanged':pins_ok,'candidate_board_sha256':meta['candidate_board_sha256'],'qsf_sha256':meta['qsf_sha256'],'baseline_actual_work':meta['baseline_actual_work'],'baseline_qsf_sha256':meta['baseline_qsf_sha256'],'effective_map_settings_match':meta['effective_baseline_map_qsf_equivalence'],'source_delta':'15bit load index plus sound diagnostic case2 compiled only under VERILATOR','baseline15_map_metrics':{'cells':771962,'registers':548181,'estimated_ALMs':372510,'block_bits':1915224,'DSP':41},'report':{'path':str(rpt),'sha256':sha(rpt)},'summary':{'path':str(summary),'sha256':sha(summary),'text':summary.read_text(encoding='utf-8-sig',errors='replace')},'resource_lines':metrics,'sound_rom_lines':sound_lines,'fit':False,'sta':False,'assembly':False,'hardware':False,'all7_fitted_resources_qualified':False,'timing_qualified':False}
(out/'terminal_result.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
