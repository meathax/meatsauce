"""Compact actual IRQ boundary interpretation, preserving all original observations."""
import csv,hashlib,json
from pathlib import Path
S=Path(__file__).resolve().parent;ROOT=S.parents[1]
CAPTURE=ROOT/'sim/captures/rtl/irq_dispatch61'
CANON=Path('/mnt/d/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
q=json.loads((S/'qualification.json').read_text());repair=json.loads((S/'collector_repair.json').read_text())
r=list(csv.DictReader((CAPTURE/'dispatch.csv').open()))
def v(x,n,s='before'):return int(x[n+'_'+s])
def compact(x):
    return {'tick':int(x['tick']),'frame':int(x['frame']),'address':int(x['address']),
        'IRQ1_before':v(x,'irq1'),'IRQ1_after':v(x,'irq1','after'),
        'IRQ2_before':v(x,'irq2'),'IRQ2_after':v(x,'irq2','after'),
        'intPend_before':v(x,'intPend'),'intPend_after':v(x,'intPend','after'),
        'rInterrupt_before':v(x,'rInterrupt'),'rInterrupt_after':v(x,'rInterrupt','after'),
        'IR_before':v(x,'Ir'),'IRD_before':v(x,'Ird'),'IRC_before':v(x,'Irc'),
        'IR_after':v(x,'Ir','after'),'IRD_after':v(x,'Ird','after'),
        'microAddr_before':v(x,'microAddr'),'microAddr_after':v(x,'microAddr','after'),
        'nma_before':v(x,'nma'),'grp1Nma_before':v(x,'grp1Nma'),
        'enT1_before':v(x,'enT1'),'enT3_before':v(x,'enT3'),
        'grp1LatchEn_before':v(x,'grp1LatchEn'),
        'PC_before':(v(x,'PcH')<<16)|v(x,'PcL'),
        'attrs_before':int(x['attrs_before']),'attrs_after':int(x['attrs_after'])}
cases=[]
for name in ['irq1','irq2']:
    assertions=[x for x in r if int(x['frame'])==59 and v(x,name)==0 and v(x,name,'after')==1]
    for a in assertions:
        tick=int(a['tick']);stop=tick+1000
        focused=[x for x in r if tick-256<=int(x['tick'])<=stop]
        groups=[compact(x) for x in focused if v(x,'enT3') and v(x,'grp1LatchEn')]
        transfers=[x for x in q['actual_IRtoIRD_strobes'] if tick-256<=x['tick']<=stop]
        pending=next((compact(x) for x in focused if v(x,'intPend')==0 and v(x,'intPend','after')==1),None)
        latch=next((compact(x) for x in focused if v(x,'rInterrupt')==0 and v(x,'rInterrupt','after')==1),None)
        entry=next((x for x in q['actual_interrupt_microsequence_entries'] if tick<=x['tick']<=stop),None)
        iack=next((compact(x) for x in focused if int(x['attrs_before'])&8==0 and int(x['attrs_after'])&8),None)
        cases.append({'IRQ':name,'assertion':compact(a),'intPend_rise':pending,
            'actual_rInterrupt_capture':latch,'actual_interrupt_microsequence_entry':entry,
            'actual_IACK_assertion':iack,'nearby_actual_group_one_latches':groups,
            'nearby_actual_IRtoIRD_strobes':transfers,
            'intervals_from_assertion_masterticks':{key:(value['tick']-tick if value else None) for key,value in [
                ('intPend_rise',pending),('rInterrupt_capture',latch),('interrupt_sequence_entry',entry),('IACK_assertion',iack)]}})
checks={'actual_build_run_and_verifier_terminal0':json.loads((S/'build_exit.json').read_text())['exit_code']==0 and json.loads((S/'run_exit.json').read_text())['exit_code']==0 and json.loads((S/'verification_exit.json').read_text())['actual_exit_code']==0,
    'all13_original_direct_boundary_checks_true':len(q['checks'])==13 and all(type(v) is bool and v for v in q['checks'].values()),
    'exact_two_original_field59_IRQ_assertions':len(cases)==2 and {x['IRQ'] for x in cases}=={'irq1','irq2'},
    'both_have_direct_pending_latch_and_sequence_entry':all(x['intPend_rise'] and x['actual_rInterrupt_capture'] and x['actual_interrupt_microsequence_entry'] for x in cases)}
rtl=Path(json.loads((S/'job.json').read_text())['build_root'])/'fx68k.sv';lines=rtl.read_text().splitlines()
source={'path':str(rtl),'sha256':sha(rtl),'excerpts':[{'first_line':a,'last_line':b,'text':'\n'.join(lines[a-1:b])} for a,b in [(177,181),(258,272),(317,325),(2105,2109),(2122,2133),(2148,2153)]]}
prior=CANON/'research/irq_mame_fx68k_boundary_review.json'
receipt={'scope':'Direct source-qualified native exception-recognition timing at the two disputed startup IRQs; no inferred MAME pending-state value.',
    'checks':checks,'finite_native_boundary_interpretation_pass':all(type(v) is bool and v for v in checks.values()),
    'cases':cases,'source':source,'prior_MAME_boundary_review':{'path':str(prior),'sha256':sha(prior)},
    'raw_qualification_recovery':{'path':str(S/'qualification.json'),'sha256':sha(S/'qualification.json'),'bytes':(S/'qualification.json').stat().st_size},
    'raw_observer_recovery':{'path':str(CAPTURE/'dispatch.csv'),'sha256':sha(CAPTURE/'dispatch.csv'),'bytes':(CAPTURE/'dispatch.csv').stat().st_size},
    'native_regression':{'frames':61,'whole_RGB_images':19,'CPU_renderer_frame_rows_exact':True,'all_whole_native_RGB_exact':True},
    'limits':['Native interrupt dispatch here means actual entry into the source-named ITLX1 microsequence, with its prior pending/priority signals observed. It is not an inferred architectural MAME instruction timestamp.',
        'Pinned MAME IR-to-IRD snapshot semantics remain source-level only; no existing capture exposes runtime m_int_next_state/m_next_state at the corresponding DBRA cutoff.',
        'Native group-one latch and IR-to-IRD strobe have different phases. Their observed temporal relation alone proves neither a physical CPU defect nor a MAME bug.',
        'No clocks, canonical RTL, pixels or field mapping changed. The raw qualification and full observer are retained, with compact records exported for review.'],
    'next_required_observation':'Source-pinned read-only MAME internal m_int_next_state/m_next_state, IR/IRD and actual IR-to-IRD cutoff around these same two IRQs, including callback epochs and existing destination writes. A private MAME build/probe must preserve the original oracle as a distinct reference; native data alone cannot fill this observation.',
    'responsible_layer_correction_justified':False,'physical_cause_proven':False,'MAME_bug_proven':False,'B16_closed':False,'full_graphics_acceptance':False}
p=S/'interpretation.json';p.write_text(json.dumps(receipt,indent=2)+'\n')
summary={'checks':checks,'cases':[{'IRQ':x['IRQ'],'assertion':x['assertion']['tick'],'intervals':x['intervals_from_assertion_masterticks'],
    'latch_IR':x['actual_rInterrupt_capture']['IR_before'] if x['actual_rInterrupt_capture'] else None,
    'latch_IRD':x['actual_rInterrupt_capture']['IRD_before'] if x['actual_rInterrupt_capture'] else None,
    'transfer_ticks':[t['tick'] for t in x['nearby_actual_IRtoIRD_strobes']]} for x in cases],
    'interpretation_sha256':sha(p),'raw_qualification_bytes':(S/'qualification.json').stat().st_size}
print(json.dumps(summary))
raise SystemExit(0 if receipt['finite_native_boundary_interpretation_pass'] else 1)
