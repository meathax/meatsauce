"""Qualify direct native boundaries; never infers an unseen MAME cutoff."""
import csv,hashlib,json
from pathlib import Path
S=Path(__file__).resolve().parent
ROOT=S.parents[1]
CAPTURE=ROOT/'sim/captures/rtl/irq_dispatch61'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def rows(p):return list(csv.DictReader(p.open()))
def v(row,name,side='before'):return int(row[name+'_'+side])
job=json.loads((S/'job.json').read_text());repair=json.loads((S/'collector_repair.json').read_text())
terminal=json.loads((S/'run_exit.json').read_text());r=rows(CAPTURE/'dispatch.csv')
layout=repair['nanod_layout'];irbit=layout['Ir2Ird']['lsb']
def ir2ird(row,side):return bool(sum(v(row,'nanod_word'+str(i),side)<<(32*i) for i in range(4))&(1<<irbit))
errors=[];groups=[];transfers=[];entries=[]
for x in r:
    gate=bool(v(x,'grp1LatchEn') and v(x,'enT3'))
    expected=v(x,'intPend') if gate else v(x,'rInterrupt')
    if v(x,'rInterrupt','after')!=expected:errors.append({'tick':x['tick'],'rule':'direct rInterrupt group-one assignment'})
    transfer=bool(v(x,'enT1') and ir2ird(x,'before'))
    expected_ird=v(x,'Ir') if transfer else v(x,'Ird')
    if v(x,'Ird','after')!=expected_ird:errors.append({'tick':x['tick'],'rule':'direct IR-to-IRD transfer'})
    ir_forward=bool(v(x,'enT1') and not ir2ird(x,'before') and v(x,'microLatch')&1)
    expected_ir=v(x,'Irc') if ir_forward else v(x,'Ir')
    if v(x,'Ir','after')!=expected_ir:errors.append({'tick':x['tick'],'rule':'direct IRC-to-IR transfer'})
    summary={'tick':int(x['tick']),'frame':int(x['frame']),'address':int(x['address']),
        'Ir_before':v(x,'Ir'),'Ird_before':v(x,'Ird'),'Irc_before':v(x,'Irc'),
        'intPend_before':v(x,'intPend'),'rInterrupt_before':v(x,'rInterrupt'),
        'rInterrupt_after':v(x,'rInterrupt','after'),'microAddr_before':v(x,'microAddr'),
        'microAddr_after':v(x,'microAddr','after'),'nma_before':v(x,'nma'),
        'grp1Nma_before':v(x,'grp1Nma'),'enT1_before':v(x,'enT1'),'enT3_before':v(x,'enT3'),
        'Ir2Ird_before':ir2ird(x,'before')}
    if gate:groups.append(summary)
    if transfer:transfers.append(summary)
    if v(x,'microAddr')!=0x1c4 and v(x,'microAddr','after')==0x1c4:entries.append(summary)
frames=rows(CAPTURE/'frames.csv')
old=ROOT/'sim/captures/rtl/irq_ipl_recognition61'
images=[]
for p in sorted(CAPTURE.glob('frame_*.rgb')):
    o=old/p.name;images.append({'field':int(p.stem.split('_')[1]),'new_sha256':sha(p),
        'old_sha256':sha(o) if o.exists() else None,'whole_RGB_equal':o.exists() and p.read_bytes()==o.read_bytes()})
frame_equal=frames==rows(old/'frames.csv')
build=Path(job['build_root'])
checks={'actual_private_build0':json.loads((S/'build_exit.json').read_text())['exit_code']==0,
    'actual_private_run0':terminal['exit_code']==0,'actual_ELF_pin':sha(build/'obj/irq_dispatch61_sim')==terminal['actual_ELF_sha256'],
    'all_hardware_source_pins_unchanged':repair['hardware_sources_unchanged'] is True and all(sha(build/name)==job['production_source_pins'][rel] for name,rel in job['copied_source_origins'].items() if name!='system_main.cpp'),
    'actual61_contiguous_frames':len(frames)==61 and all(int(x['frame'])==i for i,x in enumerate(frames)),
    'all61_renderer_metrics_complete':all(int(x['pixels'])==57344 and all(int(x[k])==0 for k in ['duplicates','deadline_misses','row_overflows']) for x in frames),
    'exact_old61_CPU_renderer_frame_rows':frame_equal,
    'all19_whole_native_RGB_equal':len(images)==19 and all(x['whole_RGB_equal'] is True for x in images),
    'nonvacuous_actual_group_one_latches':len(groups)>0,
    'nonvacuous_actual_IRtoIRD_strobes':len(transfers)>0,
    'nonvacuous_actual_interrupt_microsequence_entries':len(entries)>0,
    'direct_source_assignment_rules_exact':not errors,
    'actual_interrupt_entries_have_prior_pending_priority':all(x['rInterrupt_before']==1 and x['nma_before']==0x1c4 and x['grp1Nma_before']==0x1c4 for x in entries)}
receipt={'scope':'Actual frozen current-image native recognition boundary and interrupt microsequence entry; native-to-native fidelity only.',
    'checks':checks,'finite_direct_native_recognition_and_regression_pass':all(type(x) is bool and x for x in checks.values()),
    'group_one_latches':groups,'actual_IRtoIRD_strobes':transfers,'actual_interrupt_microsequence_entries':entries,
    'source_assignment_rule_errors':errors,'whole_native_RGB_comparisons':images,
    'source_pins':job['production_source_pins'],'nanod_IRtoIRD_packed_lsb':irbit,
    'evidence_pins':{p.name:sha(p) for p in [S/'job.json',S/'collector_repair.json',S/'build_exit.json',S/'run_exit.json',CAPTURE/'dispatch.csv',CAPTURE/'frames.csv',S/'verify.py']},
    'missing_observation':'The pinned MAME executable does not expose m_int_next_state/m_next_state and the exact IR-to-IRD pending-state cutoff in its retained Lua observer. Native sampling alone cannot establish that value or physical correctness.',
    'MAME_internal_cutoff_observed':False,'physical_cause_proven':False,'RTL_defect_proven':False,
    'MAME_bug_proven':False,'B16_closed':False,'timing_fix_proven':False,'full_graphics_acceptance':False}
p=S/'qualification.json';p.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'checks':checks,'group_one_latches':len(groups),'IRtoIRD_strobes':len(transfers),
    'interrupt_entries':entries,'errors':len(errors),'qualification_sha256':sha(p)}))
raise SystemExit(0 if receipt['finite_direct_native_recognition_and_regression_pass'] else 1)
