from pathlib import Path
import csv,hashlib,json
O=Path(__file__).resolve().parent;J=O/'p2_gameplay181'
BASE=O.parent/'stingray_combined_stage/next_coupled_scope_v2'
CAN=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf-8')
q=json.loads((J/'protocol_verification_v3.json').read_text());v=json.loads((J/'verification.json').read_text());c=json.loads((J/'source_closure.json').read_text())
for n in ['build_exit.json','run_exit.json','verification_v2_exit.json','protocol_v3_exit.json','protocol_verification_v3_exit.json']:
    assert json.loads((J/n).read_text())['exit_code']==0
assert len(q['checks'])==15 and all(q['checks'].values())
assert len(c['source_files'])==75 and len(q['compiled_hashes'])==70 and all(q['compiled_hash_checks'].values())
assert all(H(Path(r['path']))==r['candidate_sha256'] for r in c['source_files'])
assert v['all5_completed_RGB_exact'] and q['software_commands']['full_equal']
assert all(r['sprites.bin']['different_bytes']==0 for r in v['comparisons'])
credit=q['actual_coinage_consumption']['native'];start=[r for r in q['actual_start_consumption']['native'] if int(r['data_in_after'])&128]
assert credit and start and int(credit[0]['frame'])==122 and int(start[0]['frame'])==162
display=json.loads((J/'completed_texture_consumer_binding.json').read_text())
for r in display['frames']:
    assert H(Path(r['native_RGB_path']))==r['MAME_display_RGB']['sha256']
changes=[{'relative':r['relative'],'baseline_sha256':r['observer_baseline_sha256'],'candidate_sha256':r['candidate_sha256'],'effect':'Profile2 architectural P2 transaction sampling; original donor physical output pipeline and CPU/timer/ROM/clock logic preserved.'} for r in c['source_files'] if r['profile2_functional_change']]
assert len(changes)==2
ram=json.loads((J/'strict_work_differences.json').read_text())
result={'scope':'One root-authorized reviewed P2 genuine CPU/Z80/8748 gameplay181 run; no simulation rerun, production integration,1800/timing/hardware claim.','actual_exits':{n:json.loads((J/n).read_text())['exit_code'] for n in ['build_exit.json','run_exit.json','verification_v2_exit.json','protocol_v3_exit.json']},'frozen75sourcefiles_exact':True,'actual_native70recipefiles_exact':True,'frozen_unused_native_recipe_files':['alpha68kn_crt.sv','alpha68kn_pll.sv'],'source_effects':changes,'ELF':json.loads((J/'ELF.json').read_text()),'original1800row_input_used_exact181prefix':True,'input':json.loads((J/'admission.json').read_text())['input'],'completed_MAME_RGB_all5_exact':True,'raw_strip_all5_exact':True,'raw_work_differences':ram['checkpoints'],'strict_raw_RAM_gate_open':True,'actual_first_coinage_reply1':credit[0],'actual_first_start128':start[0],'ordered_MCU_commands':q['software_commands'],'finite_coin_credit_start_gameplay179_pass':True,'audio_native':q['audio_native'],'audio_MAME_fidelity_gate_open':True,'profile01_inactive_cone':pin(J/'profile01_inactive_cone.json'),'all15_current_protocol_checks_pass':True,'timing_resource_IO_hardware_gates_open':True,'failure_preservation':'Original CSV1800rows vs181consumer assertion, abortedwaiter, and protocolv2 CRT/PLL compiledset assertion remain immutable. Only readonly consumers were repaired, no rerun or changedsource/input/admission. All12rawRAMdifferences remain strict and unclassified.','next_action':'Root integration of reviewed P2/P6 only after source review; next1800requiresrootauthorization on frozen joinedgraph. RAM temporal/state diagnosis remains separate and cannot inherit anotherprofile cause.'}
save(J/'result.json',result)
(J/'REPORT.md').write_text('''# Super Stingray P2 gameplay181 qualification

The one genuine CPU/Z80/8748 run exited0. All15 current source/protocol checks pass with native verifier exit0. All75 frozen source files and all70 files compiled by the reviewed native recipe match their pins; CRT/PLL are retained in the frozen source graph and intentionally absent from this native recipe. Only the two reviewed P2 integration files change functional RTL. The World/Japan MCU cone remains held in reset and excluded from CPU pause, RAM, IRQ and flip behavior.

Full completed MAME RGB at frames0,30,90,119,179 is byte-exact, with no offsets or masks. All five strip RAM checkpoints are exact. Work RAM is exact at0/30/90; frame119 retains5 differing bytes and179 retains7, all listed in strict_work_differences.json. These remain an open rawRAM gate without an inferred stack/cutoff cause.

The main CPU consumes coinage01 at matchedPC5274 in field122 and start128 atPC4208 in field162, matching actual official MAME consumption. All38 MCU command tuples match MAME in order. Together with exact completed gameplay frame179 this qualifies the finite credit/start/gameplay sequence. The original1800-row preparedCSV was used; its first181 rows match all applied fields. Callback-derived shifted input remains an unpromoted hypothesis.

Actual audio captures146792 samples at48kHz,0 clipped samples, with406 YM,70 AY1 and656 AY2 writes. MAME audio fidelity is a separate open gate. A15/15 protocol result does not qualify1800, timing/resources, external IO or hardware.

Two readonly consumer failures are preserved: an incorrect181row assertion against the unchanged1800row inputCSV, and a compiled-set assertion that included the native-unused CRT/PLL files. Verificationv2/protocolv3 correct only these consumers and run no simulation. Source, ELF, admission and inputs remain frozen. The sole build/run and final readonly verifier exits are authentic0.
''',encoding='utf-8')
paths=list(J.glob('*.json'))+list(J.glob('*.log'))+[J/'REPORT.md']+list((J/'capture').iterdir())+list((J/'mame_completed_texture').iterdir())
paths+=[Path(r['path']) for r in c['source_files']]
paths+=[J/'source/rtl/vendor/t48/SOURCE.proposed.json',J/'source/rtl/vendor/t48/LICENSE.upstream']
paths+=[O/n for n in ['p2_gameplay181_worker.py','p2_gameplay181_verification_v2.py','verify_p2_gameplay181_protocol.py','verify_p2_gameplay181_protocol_v2.py','verify_p2_gameplay181_protocol_v3.py','stage_p2_completed_display.py','freeze_p2_gameplay181.py']]
paths+=[BASE/'gameplay_inputs.csv',O/'gameplay_inputs_after_snapshot.csv',O/'native_observer181/mame181/accepted_reads.csv',O/'native_observer181/verification.json',O/'p2_candidate_qualification_v7/import_manifest.json']
for r in display['frames']:
    paths += [Path(r['MAME_completed_PNG']['path']),Path(r['qualified_completed_RGB']['path'])]
for f in [0,30,90,119,179]:
    paths += [CAN/f'sim/captures/sstingry/gameplay/frame_{f:06d}.{n}' for n in ['work.bin','sprites.bin']]
paths=sorted(set(p for p in paths if p.is_file()),key=str)
manifest={'scope':result['scope'],'files':[pin(p) for p in paths],'prior_P2_proposal':pin(O/'p2_candidate_qualification_v7/import_manifest.json'),'strict_gates_open':['12rawRAMbytes','MAMEaudiofidelity','1800joinedgameplay','timing/resources/IO/hardware']}
save(J/'import_manifest.json',manifest)
print(json.dumps({'manifest':str(J/'import_manifest.json'),'manifest_sha256':H(J/'import_manifest.json'),'result_sha256':H(J/'result.json'),'files':len(paths),'finite_gameplay_pass':True,'protocol15of15':True,'rawRAM_different_bytes':12,'compiled_files':70,'frozen_sources':75,'CSV_files':[p.name for p in (J/'capture').glob('*.csv')]}))
