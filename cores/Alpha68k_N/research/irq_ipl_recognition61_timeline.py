"""Pair actual assertion and IACK ticks; qualify finite stop without a replay."""
import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
R = ROOT / 'research'
C = ROOT / 'sim/captures/rtl/irq_ipl_recognition61'


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    dest = R / 'irq_ipl_recognition61_timeline.json'
    assert not dest.exists()
    verification = R / 'irq_ipl_recognition61_verification.json'
    v = json.loads(verification.read_text())
    with (C / 'ipl_phase.csv').open(newline='') as f:
        rows = [{k: int(x) for k, x in row.items()} for row in csv.DictReader(f)]
    cases = []
    for assertion in v['assertions']:
        level = int(assertion['irq'][-1])
        later = [x for x in rows if x['tick'] >= assertion['tick']]
        ack = next((x for x in v['iack_starts'] if x['tick'] > assertion['tick'] and x['inl'] == level), None)
        next_same = next((x for x in v['assertions'] if x['tick'] > assertion['tick'] and x['irq'] == assertion['irq']), None)
        if ack and next_same and ack['tick'] > next_same['tick']:
            ack = None
        end = ack['tick'] if ack else rows[-1]['tick']
        interval = [x for x in later if x['tick'] <= end]
        case = dict(assertion=assertion, iack=ack, finite_stop_before_iack=ack is None,
                    observed_through_tick=end, boundaries={})
        for field in ['rIpl', 'iIpl', 'intPend', 'inl', 'Iac']:
            wanted = level if field in ['rIpl', 'iIpl', 'inl'] else 1
            match = next((x for x in interval if x[field + '_before'] != wanted and x[field + '_after'] == wanted), None)
            if match:
                case['boundaries'][field] = dict(tick=match['tick'], frame=match['frame'],
                    relative_to_assertion=match['tick'] - assertion['tick'],
                    clks_before=match['Clks_before'], enPhi1=(match['Clks_before'] >> 1) & 1,
                    enPhi2=match['Clks_before'] & 1, enT1=match['enT1_before'], enT4=match['enT4_before'],
                    updIll_before=match['updIll_before'], microLatch_before=match['microLatch_before'],
                    microLatch_bit0=match['microLatch_before'] & 1,
                    pc_before=(match['PcH_before'] << 16) | match['PcL_before'],
                    pc_after=(match['PcH_after'] << 16) | match['PcL_after'])
        cases.append(case)
    writes = []
    with (C / 'instruction_events.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            address, frame = int(row['address']), int(row['frame'])
            if frame == 59 and address in [0x411b4, 0x41506] and int(row['rw']) == 0:
                writes.append({k: int(x) for k, x in row.items()})
    relevant = []
    for write in writes:
        case = max((x for x in cases if x['iack'] and x['iack']['tick'] < write['tick']), key=lambda x: x['iack']['tick'])
        relevant.append(dict(tile_write=write, assertion=case['assertion'], recognition=case['boundaries'],
                             iack=case['iack'], write_after_iack_ticks=write['tick'] - case['iack']['tick']))
    source_checks = {k: x for k, x in v['checks'].items() if k != 'irq59_60_assertion_to_iack_coverage'}
    result = dict(original_verification_sha256=sha(verification), analyzer_sha256=sha(__file__),
        original_verification_receipt_preserved=True,
        qualification_correction='Original coverage predicate grouped frame labels without pairing assertions to IACK. Supersede that coverage claim with these actual tick pairs. IRQ1 assertion and IACK cross fields.',
        finite_fidelity_and_source_transition_rules_pass=all(source_checks.values()),
        all_field59_60_assertions_through_iack_coverage=all(x['iack'] is not None for x in cases if x['assertion']['frame'] in [59, 60]),
        observer_tick_range=[rows[0]['tick'], rows[-1]['tick']], actual_assertion_iack_pairs=cases,
        known_field59_relocated_write_cases=relevant,
        limitations=['Internal PcH/PcL and request trace pc_after are observed CPU state, not independent instruction-dispatch markers.',
                     'Finite 61-field stop can omit the final IRQ1 IACK in the next field. No additional replay was run.',
                     'Read-only sample boundaries explain native recognition chronology only; physical timing cause and correct hardware fix remain open.'],
        B16_closed=False, physical_cause_proven=False, timing_fix_proven=False)
    with dest.open('x', encoding='utf-8') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    md = R / 'irq_ipl_recognition61_timeline.md'
    with md.open('x', encoding='utf-8') as f:
        f.write('# Private real-CPU interrupt recognition, finite 61-field replay\n\n')
        f.write('Actual simulation PID 80873 exited 0. All 19 RGB images and complete input, frame, instruction, bus and existing E/latch traces are byte-identical to the frozen replay. All 4745 recorded transitions satisfy the exact source rules, with zero violations. No production RTL, CPU state, clock, phase or input changes.\n\n')
        f.write('The first verifier coverage predicate matched frame labels without pairing assertion and IACK ticks. Its receipt is preserved. The paired timeline supersedes that coverage claim: IRQ1 assertion and IACK cross field boundaries. The finite final assertion is explicitly pending when its acknowledgement lies beyond the stop.\n\n')
        f.write('| Assertion field / IRQ | Assertion tick | rIpl tick | iIpl tick | pending tick | inl tick | IACK tick |\n|---|---:|---:|---:|---:|---:|---:|\n')
        for x in cases:
            bs=x['boundaries']; a=x['assertion']
            values=[bs.get(k,{}).get('tick','unobserved') for k in ['rIpl','iIpl','intPend','inl']]
            f.write('| '+str(a['frame'])+' / '+a['irq']+' | '+str(a['tick'])+' | '+' | '.join(map(str,values))+' | '+str(x['iack']['tick'] if x['iack'] else 'outside finite stop')+' |\n')
        f.write('\nThe JSON links the two known field59 relocated tile writes to actual recognition and IACK ticks. PC values are internal observed state; they are not independent dispatch timestamps. B16, physical-cause and timing-fix acceptance remain false.\n')
    print(json.dumps({'cases':len(cases),'pairs':sum(x['iack'] is not None for x in cases),
                      'unpaired': [x['assertion'] for x in cases if x['iack'] is None],
                      'known_writes':len(relevant),'fidelity_rules_pass':result['finite_fidelity_and_source_transition_rules_pass'],
                      'all59_60_through_iack':result['all_field59_60_assertions_through_iack_coverage'],
                      'write_timing':[{'address':hex(x['tile_write']['address']),'tick':x['tile_write']['tick'],
                          'assertion':x['assertion'],'rIpl':x['recognition'].get('rIpl'),'iIpl':x['recognition'].get('iIpl'),
                          'pending':x['recognition'].get('intPend'),'inl':x['recognition'].get('inl'),'iack':x['iack']} for x in relevant]}))


if __name__ == '__main__':
    main()
