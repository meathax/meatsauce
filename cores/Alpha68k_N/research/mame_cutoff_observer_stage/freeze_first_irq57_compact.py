import hashlib
import json
from pathlib import Path

stage = Path(__file__).resolve().parent
released = stage / 'first_irq_native57_released1'
primary = released / 'interpretation'
out = released / 'compact_cause'
assert not out.exists(), 'Immutable supplement already exists; do not overwrite'

def pin(p):
    b = p.read_bytes()
    return {'path': str(p), 'bytes': len(b), 'sha256': hashlib.sha256(b).hexdigest()}

report_path = primary / 'report.json'
manifest_path = primary / 'import_manifest.json'
assert pin(report_path)['sha256'] == '89cd1cedfebd99942a59529aa1b0e40614580888c6f4356727f4552aca33037d'
assert pin(manifest_path)['sha256'] == 'ec16ad320f96e967f101735fc127b890541398c46ca10f466e0a622d19ebcf87'
d = json.loads(report_path.read_text())
assert d['actual_guest_invariance_accepted'] and not d['B16_closed']
assert not d['physical_cause_proven'] and d['no_CPU_or_clock_or_IRQ_patch']
assert d['no_MAME_rerun'] and d['guest_runs'] == 1
contract_path = Path(d['source_contract']['path'])
assert pin(contract_path) == d['source_contract']
contract = json.loads(contract_path.read_text())
fx = Path(contract['FX_E_VPA']['source']['path'])
assert pin(fx) == contract['FX_E_VPA']['source']
lines = fx.read_text().splitlines()
source_indices = set()
for i, line in enumerate(lines):
    if 'waitBusCycle' in line or 'xVma' in line:
        source_indices.update(range(max(0, i-3), min(len(lines), i+5)))
bus_wait_source = [{'line': i+1, 'text': lines[i]} for i in sorted(source_indices)]
rows = d['IACK_actual_native']['ordered_E_VPA_VMA_clock_micro_changes']
signals = ['asn', 'vpai', 'vma_n', 'xvma_derived', 'wclk']
transitions = [{'tick': r['tick'], 'signal': s,
                'before': r[s+'_before'], 'after': r[s+'_after'],
                'Ecounter_before': r['e_counter_before'],
                'Ecounter_after': r['e_counter_after'],
                'AS_after': r['asn_after']}
               for r in rows for s in signals if r[s+'_before'] != r[s+'_after']]
def event(tick, signal, before, after):
    matches = [r for r in transitions if (r['tick'], r['signal'], r['before'], r['after']) == (tick, signal, before, after)]
    assert len(matches) == 1, (tick, signal)
    return matches[0]
sequence = [event(45732665, 'asn', 1, 0), event(45732673, 'vpai', 1, 0),
            event(45732749, 'vma_n', 1, 0), event(45732781, 'xvma_derived', 0, 1),
            event(45732789, 'xvma_derived', 1, 0), event(45732793, 'wclk', 1, 0),
            event(45732797, 'asn', 0, 1), event(45732801, 'vma_n', 0, 1)]
gate = next(r for r in rows if r['tick'] == 45732669)
assert gate['e_counter_before'] == 3 and gate['e_counter_after'] == 4
assert gate['vpai_before'] == 1 and gate['vma_n_after'] == 1
compact = {
    'scope': 'ONE genuine native-only57 first-IRQ diagnostic; frozen old69 source temporal baseline; not current43b complete-game proof',
    'actual_statuses': d['actual_statuses'],
    'qualification': d['qualification'],
    'original_guest_invariance_accepted': True,
    'availability_limit': 'Original shared0/30 arrays, nine sharedCSVs, audio prefix and frozen69 files qualified; new56 snapshot has no baseline56 snapshot',
    'stack_word_bus_boundaries': d['stack_word_bus_boundaries'],
    'MAME_actual_retained_callbacks': d['MAME_actual_retained_callbacks'],
    'offsets_and_same_write_elapsed_intervals': d['offsets_and_same_write_elapsed_intervals'],
    'actual_IACK_E_VPA_sequence': sequence,
    'missed_first_VMA_gate': {k: gate[k] for k in ['tick','e_counter_before','e_counter_after','vpai_before','vma_n_before','vma_n_after','clks_before']},
    'ordered_phase_transitions': transitions,
    'FX_buswait_source_snippets': bus_wait_source,
    'source_contract_pin': pin(contract_path),
    'source_consistency': 'VPA is sampled onPhi1. At45732669 oldEcounter3 and oldVpai1 prevent VMA assertion. RegisteredVpai becomes0 on45732673. Next Ecounter3 Phi2 gate assertsVMA on45732749. DerivedxVMA atcounter8, subsequent actualwClk release and AS ending are distinct boundaries.',
    'responsible_interval': 'PCloAS toSRAS is208 native versus200 MAME callbacks. Offset42 beforeIACK becomes50 afterIACK; ordinary stack writes allAS→DS8 andDS→acceptedRAMcommit1, excluding additional ordinaryRAMport latency in this interval.',
    'MAME_model_contract': 'Defaultautovector vpa_sync uses CPU-local current_time%10 threshold7, rounds next10/20, then vpa_after1. MAMEcallback occurs afterbefore_time, beforeafter_delay; neither callback nor CPU-local arithmetic is a physicalAS edge.',
    'bounded_conclusion': 'First8 of additional24 ticks localizes to autovector E/VPA service phase/placement. FX sequence matches retained source. No physical donor orPCB timing defect established. Remaining16 ticks and strictB16 remain open.',
    'minimum_next_proof': 'Before any timing fix, join actual MAME CPU-local vpa_sync request/return cycle phase with physical68000 E/VPA/IACK contract and nativeE reset/phase contract. Existing callbacks alone do not prove MAME request-phase or PCB alignment. No newrun is launched by this proposal.',
    'B16_closed': False, 'physical_cause_proven': False,
    'CPU_clock_IRQ_guest_patch': False, 'new_MAME_runs': 0, 'native_runs': 1,
    'primary_manifest': pin(manifest_path), 'primary_report': pin(report_path)
}
out.mkdir()
output_path = out / 'report.json'
output_path.write_text(json.dumps(compact, indent=2)+'\n', encoding='utf-8')
supplement = {'scope': compact['scope'], 'entries': [pin(output_path), pin(Path(__file__)), pin(contract_path), pin(manifest_path), pin(report_path)], 'immutable_primary_unchanged': True}
supplement_path = out / 'import_manifest.json'
supplement_path.write_text(json.dumps(supplement, indent=2)+'\n', encoding='utf-8')
assert pin(report_path) == compact['primary_report'] and pin(manifest_path) == compact['primary_manifest']
assert all(pin(Path(e['path'])) == e for e in supplement['entries'])
print(json.dumps({'actual_exit': 0, 'manifest': pin(supplement_path), 'report': pin(output_path), 'exact_IACK_sequence': sequence, 'wait_source': bus_wait_source}, separators=(',', ':')))
