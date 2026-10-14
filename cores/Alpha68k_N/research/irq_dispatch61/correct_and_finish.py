"""Preserve label-selected extraction; export the exact original tick-paired cases."""
import hashlib,json,subprocess
from pathlib import Path
S=Path(__file__).resolve().parent;ROOT=S.parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
prior=Path('/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/research/irq_mame_fx68k_boundary_review.json')
review=json.loads(prior.read_text())
expected={x['assertion']['irq']:x['assertion']['tick'] for x in review['actual_native_recognition']}
assert expected=={'irq1':47849465,'irq2':48000000},expected
text=(S/'interpret.py').read_text()
old="assertions=[x for x in r if int(x['frame'])==59 and v(x,name)==0 and v(x,name,'after')==1]"
new="assertions=[x for x in r if int(x['tick'])=="+repr(expected)+"[name] and v(x,name)==0 and v(x,name,'after')==1]"
assert text.count(old)==1
text=text.replace(old,new).replace("'exact_two_original_field59_IRQ_assertions'","'exact_two_original_tick_paired_IRQ_assertions'")
text=text.replace("p=S/'interpretation.json'","p=S/'original_tick_interpretation.json'")
script=S/'interpret_original_ticks.py';script.write_text(text)
p=subprocess.run(['python3',str(script)],capture_output=True,text=True)
with (S/'original_tick_interpretation_check_exit.json').open('x') as f:
    json.dump({'actual_exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr,
        'original_fieldlabel_script_sha256':sha(S/'interpret.py'),'corrected_script_sha256':sha(script),
        'prior_boundary_review_sha256':sha(prior)},f,indent=2);f.write('\n')
assert p.returncode==0,(p.stdout,p.stderr)
d=json.loads((S/'original_tick_interpretation.json').read_text())
d['qualification_correction']={
    'original_label_selected_receipt_sha256':sha(S/'interpretation.json'),
    'original_label_selected_actual_exit_receipt_sha256':sha(S/'interpretation_check_exit.json'),
    'reason':'Frame59 predicate selected next IRQ1 assertion48660473. Use exact original pinned ticks47849465/48000000; preserve observed frame labels without shifting.',
    'original_assertion_ticks':expected,
    'native_tick_paired_selection_pass':{x['IRQ']:x['assertion']['tick'] for x in d['cases']}==expected}
out=S/'compact_acceptance.json';out.write_text(json.dumps(d,indent=2)+'\n')
q=json.loads((S/'qualification.json').read_text())
qcompact={'scope':q['scope'],'checks':q['checks'],
    'finite_direct_native_recognition_and_regression_pass':q['finite_direct_native_recognition_and_regression_pass'],
    'group_one_latch_count':len(q['group_one_latches']),'actual_IRtoIRD_strobe_count':len(q['actual_IRtoIRD_strobes']),
    'actual_interrupt_microsequence_entries':q['actual_interrupt_microsequence_entries'],
    'whole_native_RGB_comparisons':q['whole_native_RGB_comparisons'],
    'source_pins':q['source_pins'],'nanod_IRtoIRD_packed_lsb':q['nanod_IRtoIRD_packed_lsb'],
    'raw_receipt_recovery':d['raw_qualification_recovery'],'evidence_pins':q['evidence_pins'],
    'missing_observation':q['missing_observation'],'MAME_internal_cutoff_observed':False,
    'physical_cause_proven':False,'RTL_defect_proven':False,'MAME_bug_proven':False,'B16_closed':False,
    'full_graphics_acceptance':False}
(S/'compact_native_qualification.json').write_text(json.dumps(qcompact,indent=2)+'\n')
notes=['The private actual61 probe build, run and verifier exited0. All13 direct source-rule/fidelity checks passed: 61CPU/renderer rows and19whole native RGB images equal the prior qualified IPL61 run.',
    'The first collector mapping failed before make/CPU launch because group-one signals belong to the nested sequencer. The same generated model was repaired; the failure is retained.',
    'The first compact extraction selected by frame59 and picked the next IRQ1 assertion. Its actual receipt is retained. The corrected extraction selects original assertion ticks from the pinned source review; it changes no frame label, pixel or epoch.']
for x in d['cases']:
    notes.append('Original '+x['IRQ']+' assertion '+str(x['assertion']['tick'])+' is observed in native field'+str(x['assertion']['frame'])+'. Pending/latch/sequence/IACK intervals in masterticks: '+json.dumps(x['intervals_from_assertion_masterticks'])+'.')
notes.append('Direct native microsequence entry is proved. Runtime MAME m_int_next_state/m_next_state at the corresponding DBRA IR-to-IRD cutoff remains unobserved; source semantics and shared micro/nanocode cannot replace that observation. No CPU/clock correction is justified yet. B16, physical cause and full graphics acceptance remain open. Raw21MB qualification/full observer stay immutable recovery artifacts; the portable compact receipts pin them.')
(S/'interpretation.md').write_text('\n\n'.join(notes)+'\n')
files=sorted(x for x in S.iterdir() if x.is_file() and x.name not in ['qualification.json','import_manifest.json'])
manifest={'scope':'Direct native61 IRQ-recognition evidence and exact-original-tick interpretation; preserve initial failures and unknown MAME cutoff.',
    'files':[{'relative_path':x.relative_to(ROOT).as_posix(),'sha256':sha(x),'bytes':x.stat().st_size} for x in files],
    'recovery_only_large_artifacts':[d['raw_qualification_recovery'],d['raw_observer_recovery']]}
m=S/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'actual_interpretation_exit':p.returncode,'cases':[{'IRQ':x['IRQ'],'assertion':x['assertion']['tick'],
    'native_field':x['assertion']['frame'],'intervals':x['intervals_from_assertion_masterticks'],
    'latch_IR':x['actual_rInterrupt_capture']['IR_before'],'latch_IRD':x['actual_rInterrupt_capture']['IRD_before'],
    'transfer_ticks':[t['tick'] for t in x['nearby_actual_IRtoIRD_strobes']]} for x in d['cases']],
    'manifest_sha256':sha(m),'files':len(files),'portable_bytes':sum(x.stat().st_size for x in files),
    'compact_acceptance_sha256':sha(out),'compact_native_qualification_sha256':sha(S/'compact_native_qualification.json')}))
