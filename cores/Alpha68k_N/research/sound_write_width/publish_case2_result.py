"""Archive compact actual MAP receipts for central integration; leave sources read-only."""
from pathlib import Path
import hashlib,json
base=Path(__file__).resolve().parent
out=base/'case2_full_map'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
record=json.loads((out/'terminal_result.json').read_text())
assert record['actual_exit_code']==0 and record['actual_tool_chunk']=='544b0f'
assert any('Simple Dual Port' in row and '524288' in row for row in record['sound_rom_lines'])
record['actual_native_output_metrics']={'logic_cells':40662,'registers':24000,'RAM_segments':1363,'block_bits':2439512,'DSP':41,'elapsed_seconds':191,'CPU_seconds':194,'peak_virtual_MB':6661,'errors':0,'warnings':1471}
record['source_bound_conclusion']='Given the proved write15 candidate, guarding the unused physical sound diagnostic case2 makes the complete real T80/sys_top graph infer all524288 soundROM bits. No CPUwordread/latency/clock change was made. The isolated write15 success alone had failed in full integration.'
record['limit']='This native MAP closes inference only. No fit/STA, all-corner timing, fitted seven-resource thresholds, physical hardware, gameplay or audio acceptance is implied.'
(out/'terminal_result.json').write_text(json.dumps(record,indent=2)+'\n')
meta=json.loads((out/'prepared.json').read_text())
meta.pop('effective_baseline_qsf_equivalence',None)
meta['status']='native_MAP_terminal_0'
(out/'prepared.json').write_text(json.dumps(meta,indent=2)+'\n')
note='''Full sys_top candidate MAP completed with actual exit0, native session65792 and terminal tool chunk544b0f. The existing46508 full MAP is reused as the baseline; no second baseline was launched. Its actual effective QSF44aa5437df8a7a8a44f0bf9ec28455f4d1ef84ba04abd5f0ed6d9ff08a997baf was cloned, roots rebased to161 frozen byte-identical source pins and the board changed only by putting diagnostic case2 under VERILATOR. The assembly-only GENERATE_RBF_FILE option was explicitly forced OFF (old effective baseline was ON); only quartus_map was invoked.

The original full write15 candidate used771962 logic cells and548181 registers, with1915224 block bits and1299 RAM segments. Adding the physical debug guard gives40662 cells,24000 registers,2439512 block bits and1363 segments. The soundROM is now32768x16 Simple Dual Port RAM containing524288bits, adding exactly64 RAM segments; DSP stays41. Actual map runtime3m11s, CPU3m14s, peak virtual6661MB,0 errors and1471 inherited/other warnings.

This proves the extra diagnostic reader was the remaining full-context inference blocker given write15. Original simulation diagnostic code stays exact with VERILATOR defined; physical MiSTer top ties diagnostic kind0 and leaves its output unconsumed. CPUwordreader, lane/select, T80 accepted DI, loader guard, clock and all other RAMs remain unchanged. Production sources were not edited by this agent. Central integration should apply both narrow changes, then qualify the complete joined current graph through fit and all-corner STA.

No fitter, STA, assembler, RBF, queue slot or hardware was used. No fitted seven-resource or timing pass is claimed. Authentic reports and the frozen161-file input tree remain in this private run directory and are hash-addressed in terminal_result.json.
'''
(out/'result_summary.md').write_text(note)
names=['prepare_case2_guard.py','freeze_case2_guard.py','finalize_case2_guard.py','publish_case2_result.py','inspect_owned_jobs.py','case2_guard_rejections.json','owned_jobs_observation.json','case2_full_map/alpha68kn_board.sv','case2_full_map/Alpha68k_N.qpf','case2_full_map/Alpha68k_N.qsf','case2_full_map/prepared.json','case2_full_map/native_launch.json','case2_full_map/terminal_result.json','case2_full_map/result_summary.md']
manifest={'files':[{'path':name,'bytes':(base/name).stat().st_size,'sha256':sha(base/name)} for name in names],'recovery_reports':[record['report'],{k:v for k,v in record['summary'].items() if k!='text'}],'actual_MAP_exit':0,'canonical_edits':False,'source_delta':'write15 plus physical debug case2 guard','fit':False,'sta':False,'rbf':False}
target=base/'case2_import_manifest.json'
target.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'manifest':str(target),'manifest_sha256':sha(target),'files':len(names),'terminal_result_sha256':sha(out/'terminal_result.json'),'rejections_sha256':sha(base/'case2_guard_rejections.json'),'verified_sound_RAM_bits':524288,'MAP_exit':0}))
