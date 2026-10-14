"""Qualify private observer against immutable latch replay and exact fx68k rules."""
import csv
import hashlib
import json
import os
from pathlib import Path

def resolve_evidence_root():
    """Explicit evidence root or nearest marked project, within eight ancestors."""
    override = os.environ.get('ALPHA68KN_EVIDENCE_ROOT')
    if override is not None:
        if not override.strip():
            raise ValueError('ALPHA68KN_EVIDENCE_ROOT must be an absolute project path')
        candidate = Path(override).expanduser()
        if not candidate.is_absolute():
            raise ValueError('ALPHA68KN_EVIDENCE_ROOT must be absolute')
        candidate = candidate.resolve()
        if not ((candidate / 'plan.md').is_file() and
                (candidate / 'rtl/alpha68kn_board.sv').is_file()):
            raise FileNotFoundError('Evidence root lacks plan.md or rtl/alpha68kn_board.sv: ' + str(candidate))
        return candidate
    for candidate in list(Path(__file__).resolve().parents)[:8]:
        if ((candidate / 'plan.md').is_file() and
                (candidate / 'rtl/alpha68kn_board.sv').is_file()):
            return candidate
    raise FileNotFoundError('No marked project in eight ancestors; set ALPHA68KN_EVIDENCE_ROOT')


ROOT = resolve_evidence_root()
NAME = 'irq_ipl_recognition61'
R = ROOT / 'research'
C = ROOT / 'sim/captures/rtl' / NAME
B = ROOT / 'sim/captures/rtl/irq_sampling_edge_latch61'


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def load(suffix):
    return json.loads((R / (NAME + '_' + suffix + '.json')).read_text())


def main():
    output = R / (NAME + '_verification.json')
    assert not output.exists(), 'Preserve existing verification'
    repaired = (R / (NAME + '_source_v2.json')).exists()
    job, source, running, terminal = map(load, ['job', 'source_v2' if repaired else 'source', 'running', 'exit'])
    checks = {}
    checks['actual_terminal_zero'] = terminal['exit_code'] == 0 and terminal['pid'] == running['pid']
    checks['private_build_and_generation_zero'] = load('repair_build_exit' if repaired else 'build_exit')['exit_code'] == 0 and load('generation_exit')['exit_code'] == 0
    checks['actual_executable_pin'] = terminal['executable_sha256'] == running['executable_sha256'] == sha(C / (NAME + '_sim'))
    checks['original_inputs_rom_pinned'] = sha(ROOT / 'roms/kyros/download.bin') == job['rom_sha256'] and sha(ROOT / 'sim/captures/kyros/warm_reset960_refv2/frame_states.csv') == job['input_trace_sha256']
    checks['all_frozen_source_pins'] = all(sha(ROOT / p) == h for p, h in job['source_pins'].items())
    checks['private_host_configuration_pins'] = sha(ROOT / 'sim/captures/diagnostics' / (NAME + '_source/system_main.cpp')) == source['generated_host_sha256'] and sha(ROOT / 'sim/captures/diagnostics' / (NAME + '_source/observer.vlt')) == source['observer_configuration_sha256']
    checks['retained_packed_field_widths'] = source['field_mapping']['Clks']['width'] == 5 and source['field_mapping']['microLatch']['width'] == 17
    fidelity = {p: {'baseline_sha256': sha(B / p), 'observer_sha256': sha(C / p), 'identical': (B / p).read_bytes() == (C / p).read_bytes()}
                for p in ['frames.csv', 'instruction_events.csv', 'applied_inputs.csv', 'e_phase.csv', 'latch_phase.csv', 'bus.csv']}
    checks['unchanged_actual_input_instruction_bus_and_existing_observers'] = all(v['identical'] for v in fidelity.values())
    images = {p.name: {'baseline_sha256': sha(p), 'observer_sha256': sha(C / p.name), 'identical': p.read_bytes() == (C / p.name).read_bytes()} for p in B.glob('*.rgb')}
    checks['all19_native_rgb_identical'] = len(images) == 19 and all(v['identical'] for v in images.values())
    with (C / 'frames.csv').open(newline='') as f:
        frames = list(csv.DictReader(f))
    checks['61_actual_fields_renderer_complete'] = len(frames) == 61 and [int(x['frame']) for x in frames] == list(range(61)) and all(int(x['pixels']) == 57344 and int(x['duplicates']) == 0 and int(x['deadline_misses']) == 0 for x in frames)
    with (C / 'ipl_phase.csv').open(newline='') as f:
        rows = [{k: int(v) for k, v in x.items()} for x in csv.DictReader(f)]
    names = list(source['field_mapping'])
    checks['captured_fields_in_width_range'] = bool(rows) and all(0 <= row[n + '_' + side] < (1 << source['field_mapping'][n]['width']) for row in rows for n in names for side in ['before', 'after'])
    violations = []
    transitions = []
    assertions = []
    ack_starts = []
    for row in rows:
        b = {n: row[n + '_before'] for n in names}
        a = {n: row[n + '_after'] for n in names}
        phi2 = b['Clks'] & 1
        reset = (b['Clks'] >> 3) & 1
        powerup = (b['Clks'] >> 2) & 1
        expected = dict(b)
        if not powerup and phi2:
            expected['rIpl'] = 7 ^ (b['IPL0n'] | (b['IPL1n'] << 1) | (b['IPL2n'] << 2))
            expected['iIpl'] = b['rIpl']
        if reset:
            expected.update(intPend=0, prevNmi=0, inl=7, updIll=0)
        else:
            if phi2:
                nmi, stable, comp = b['iIpl'] == 7, b['iIpl'] == b['rIpl'], b['iIpl'] > b['pswI']
                expected['prevNmi'] = int(nmi)
                if stable and ((nmi and not b['prevNmi']) or comp):
                    expected['intPend'] = 1
                elif (b['inl'] == 7 and b['Iac']) or (stable and not nmi and not comp):
                    expected['intPend'] = 0
            if b['enT4']:
                expected['updIll'] = b['microLatch'] & 1
            elif b['enT1'] and b['updIll']:
                expected['inl'] = b['iIpl']
        for n in ['rIpl', 'iIpl', 'prevNmi', 'intPend', 'updIll', 'inl']:
            if a[n] != expected[n]:
                violations.append({'tick': row['tick'], 'frame': row['frame'], 'field': n, 'before': b[n], 'actual': a[n], 'expected': expected[n]})
        for side, v in [('before', b), ('after', a)]:
            level = 2 if v['irq2'] else 1 if v['irq1'] else 0
            external = 7 ^ (v['IPL0n'] | (v['IPL1n'] << 1) | (v['IPL2n'] << 2))
            if external != level or v['level'] != level:
                violations.append({'tick': row['tick'], 'side': side, 'field': 'board_external_IPL_priority'})
        rises = [n for n in ['irq1', 'irq2'] if not b[n] and a[n]]
        for n in rises:
            assertions.append({'tick': row['tick'], 'frame': row['frame'], 'irq': n})
        if not (row['attrs_before'] & 8) and row['attrs_after'] & 8:
            ack_starts.append({'tick': row['tick'], 'frame': row['frame'], 'address': row['address'], 'inl': a['inl']})
        changed = [n for n in ['irq1', 'irq2', 'rIpl', 'iIpl', 'intPend', 'updIll', 'inl', 'Iac'] if b[n] != a[n]]
        if changed:
            transitions.append({'tick': row['tick'], 'frame': row['frame'], 'changed': changed,
                                'before': {n: b[n] for n in ['level', 'rIpl', 'iIpl', 'intPend', 'inl', 'updIll', 'Iac', 'Clks', 'microLatch', 'enT1', 'enT4', 'PcH', 'PcL']},
                                'after': {n: a[n] for n in ['level', 'rIpl', 'iIpl', 'intPend', 'inl', 'updIll', 'Iac', 'PcH', 'PcL']}})
    checks['all_captured_source_exact_interrupt_transition_rules'] = not violations
    # Pair ticks rather than frame labels: IRQ1 assertion and IACK cross fields.
    requested_assertions = [x for x in assertions if x['frame'] in [59, 60]]
    pairs = []
    for assertion in requested_assertions:
        level = int(assertion['irq'][-1])
        ack = next((x for x in ack_starts if x['tick'] > assertion['tick'] and x['inl'] == level), None)
        next_same = next((x for x in assertions if x['tick'] > assertion['tick'] and x['irq'] == assertion['irq']), None)
        if ack and next_same and ack['tick'] > next_same['tick']:
            ack = None
        pairs.append({'assertion': assertion, 'iack': ack})
    checks['irq59_60_assertion_to_iack_coverage'] = len(requested_assertions) == 4 and all(x['iack'] is not None for x in pairs)
    fidelity_pass = all(x for k, x in checks.items() if k != 'irq59_60_assertion_to_iack_coverage')
    result = dict(scope='Finite frozen real CPU recognition observer. PC is internal exception-unit state, not a dispatch timestamp. No phase/clock correction or physical-cause claim.',
                  checks=checks, finite_observer_fidelity_pass=fidelity_pass,
                  all_requested_assertions_through_iack=checks['irq59_60_assertion_to_iack_coverage'],
                  assertion_iack_tick_pairs=pairs,
                  B16_closed=False, physical_cause_proven=False, timing_fix_proven=False,
                  verifier_sha256=sha(__file__), source_job_sha256=sha(R / (NAME + '_job.json')),
                  focused_build_repair=repaired, original_build_exit=load('build_exit'),
                  actual_terminal=terminal, source_pin_count=len(job['source_pins']),
                  fidelity=fidelity, images=images, observer_rows=len(rows),
                  assertions=assertions, iack_starts=ack_starts, transitions=transitions,
                  violations=violations[:100], violation_count=len(violations),
                  optional_A0='Not read directly; existing actual saved-A0 bus evidence remains separate.')
    with output.open('x', encoding='utf-8') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    print(json.dumps({'pass': result['finite_observer_fidelity_pass'], 'checks': checks, 'rows': len(rows), 'violations': len(violations), 'receipt': str(output)}))
    return 0 if result['finite_observer_fidelity_pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
