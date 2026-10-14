"""Conservative finite source/state join. No CPU execution or replay."""
import ast
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
R = ROOT / 'research'
C = ROOT / 'sim/captures/rtl/irq_ipl_recognition61'
FX = ROOT / 'rtl/vendor/fx68k'
CANONICAL = Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def write(name, obj):
    with (R / name).open('x', encoding='utf-8') as f:
        json.dump(obj, f, indent=2)
        f.write('\n')


def import_safety():
    stage = R / 'irq_ipl_recognition61_adapted/scripts/diagnostics'
    manifest = R / 'irq_ipl_recognition61_adapted_import_manifest.json'
    assert sha(manifest) == 'ff9ad0ea2f4db0a094bf166576961c2660c34c03c972b8154bfceb148446ebb9'
    for name in ['irq_ipl_recognition61_probe.py', 'repair_irq_ipl_recognition61_build.py']:
        tree = ast.parse((stage / name).read_text())
        guards = [n for n in tree.body if isinstance(n, ast.If)]
        assert len(guards) == 1
        assert ast.dump(guards[0].test) == ast.dump(ast.parse("__name__ == '__main__'", mode='eval').body)
        assert not guards[0].orelse and len(guards[0].body) == 1
        assert isinstance(guards[0].body[0], ast.Expr) and isinstance(guards[0].body[0].value, ast.Call)
        assert isinstance(guards[0].body[0].value.func, ast.Name) and guards[0].body[0].value.func.id == 'main'
        assert all(isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.Assign, ast.Expr, ast.If)) for n in tree.body)
    env = dict(os.environ, ALPHA68KN_EVIDENCE_ROOT=str(CANONICAL))
    code = "import sys,json;sys.path.insert(0,sys.argv[1]);import irq_ipl_recognition61_probe as p;import repair_irq_ipl_recognition61_build as r;print(json.dumps({'probe_root':str(p.ROOT),'repair_root':str(r.ROOT),'same_root':p.ROOT==r.ROOT,'main_not_invoked':True}))"
    proc = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(stage)],
                          env=env, capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    result = json.loads(proc.stdout)
    assert Path(result['probe_root']) == CANONICAL and result['same_root']
    runtime = ROOT / 'sim/captures/diagnostics/irq_ipl_recognition61_source/irq_ipl_recognition61_probe_runtime_v1.py'
    assert sha(runtime) == '7016b032104fc22f432d2cc959343fd264bdb566146d857ebee6bbc7f2099586'
    write('irq_ipl_recognition61_import_safety.json', dict(
        scope='AST guarded-main review plus isolated import-only subprocess; no helper main/CLI/replay.',
        command=[sys.executable, '-I', '-B', '-c', code, str(stage)],
        exit_code=proc.returncode, stdout=result, stderr=proc.stderr,
        adapted_manifest_sha256=sha(manifest), adapted_manifest_unchanged=True,
        imported_module_pins={p.name: sha(p) for p in [stage / 'irq_ipl_recognition61_probe.py', stage / 'repair_irq_ipl_recognition61_build.py']},
        runtime_probe_archive_sha256=sha(runtime), import_safe=True))


def nanocode():
    path = Path('D:/Arcade/AI/mame289/src/devices/cpu/m68000/m68000gen.py')
    tree = ast.parse(path.read_text())
    base = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'nanocode_base_table' for t in n.targets))
    mame = [next((x[2][a & 3] for x in base if a & x[1] == x[0]), [0, 0x10000, 0]) for a in range(1024)]
    source = (FX / 'fx68k.sv').read_text()
    module = source[source.index('module microToNanoAddr('):]
    mapping = {int(a, 16): int(b, 16) for a, b in re.findall(r"'h([0-9a-fA-F]+):\s*orgBase\s*=\s*7'h([0-9a-fA-F]+)", module)}
    words = [int(x.strip(), 2) for x in (FX / 'nanorom.mem').read_text().splitlines() if x.strip()]
    comparisons = []
    for address in range(1024):
        if address >> 2 not in mapping:
            continue
        compact = (mapping[address >> 2] << 2) | (address & 3)
        if compact >= len(words):
            continue
        value = (mame[address][0] << 64) | (mame[address][1] << 32) | mame[address][2]
        # MAME nanox bit0 is IR2IRD; fx68k NANO_IR2IRD is bit67.
        oriented = int(format(value, '068b')[::-1], 2)
        comparisons.append(dict(microaddress=address, compact_address=compact,
                                match=words[compact] == oriented,
                                fx_word_hex=hex(words[compact]), mame_reversed68_hex=hex(oriented)))
    used = sorted({x['compact_address'] for x in comparisons})
    default = re.search(r'default:\s*orgBase\s*=\s*([^;]+);', module)
    result = dict(scope='Static source/data comparison only; not observed nanolatch or dispatch.',
                  source_pins={str(p): sha(p) for p in [path, FX / 'fx68k.sv', FX / 'nanorom.mem']},
                  orientation='Pack MAME[n0:n1:n2] as68bits, reverse68bit numbering. MAME nanox(start0)=IR2IRD corresponds to fx68k bit67.',
                  mapping_source_lines=[2493, 2499, 2504], forwarding_source_lines=[663, 808],
                  mame_nanox_source_lines=[813, 819, 1106],
                  compact_words=len(words), mapped_microaddresses_compared=len(comparisons),
                  compact_words_covered=len(used), all_compact_words_covered=used == list(range(len(words))),
                  all_mapped_words_equal=all(x['match'] for x in comparisons),
                  differences=[x for x in comparisons if not x['match']],
                  mapper_default_expression=default.group(1).strip() if default else 'unparsed',
                  unmapped_microaddresses=1024 - len(comparisons),
                  limitations='Unmapped/default addresses are not asserted equivalent. Equal stored words do not prove identical latch timing or dispatch policy.')
    write('irq_fx_mame_nanocode_comparison.json', result)
    return result


def allowed(state, phase, ent1, ent4):
    phi1, phi2 = (phase >> 1) & 1, phase & 1
    if int(bool(phi2 and state in [0, 3])) != ent4:
        return False
    if ent1 and not (phi1 and state == 4):
        return False
    return True


def advance(state, phase, ent1):
    if phase & 4:  # Clks.pwrUp; extReset does not reset this FSM.
        return 0
    phi1, phi2 = (phase >> 1) & 1, phase & 1
    if state == 0 and phi2:
        return 4
    if state == 1 and phi2:
        return 2
    if state == 2 and phi1:
        return 3
    if state == 3 and phi2:
        return 4
    if state == 4 and phi1:
        # enT1 observed1 proves wClk0; observed0 at T4/Phi1 proves wClk1.
        return 1 if ent1 else 0
    return state


def main():
    assert not (R / 'irq_ipl_recognition61_state_join.json').exists()
    import_safety()
    nano = nanocode()
    with (C / 'ipl_phase.csv').open(newline='') as f:
        rows = [{k: int(v) for k, v in x.items()} for x in csv.DictReader(f)]
    timeline_path = R / 'irq_ipl_recognition61_timeline.json'
    timeline = json.loads(timeline_path.read_text())
    micro = [int(x.strip(), 2) for x in (FX / 'microrom.mem').read_text().splitlines() if x.strip()]
    states, previous, segment = set(), None, -1
    derived, updates, violations = [], [], []
    for row in rows:
        if previous is None or row['tick'] != previous + 1:
            states = {(s, interrupt) for s in range(5) for interrupt in [0, 1]}
            segment += 1
        before = {(s, i) for s, i in states if allowed(s, row['Clks_before'], row['enT1_before'], row['enT4_before'])}
        en3 = {int(bool(((row['Clks_before'] >> 1) & 1) and s == 2)) for s, _ in before}
        word = row['microLatch_before']
        group1 = int(bool((word & 1) and (((word >> 1) & 1) or not ((word >> 4) & 1))))
        update = {int(bool(group1 and en)) for en in en3}
        after = set()
        for s, i in before:
            enable = bool(group1 and ((row['Clks_before'] >> 1) & 1) and s == 2)
            next_i = row['intPend_before'] if enable else i
            next_s = advance(s, row['Clks_before'], row['enT1_before'])
            if allowed(next_s, row['Clks_after'], row['enT1_after'], row['enT4_after']):
                after.add((next_s, next_i))
        if not before or not after:
            violations.append(dict(tick=row['tick'], frame=row['frame'], segment=segment,
                                   before_candidates=sorted(before), after_candidates=sorted(after)))
        entry = dict(tick=row['tick'], frame=row['frame'], segment=segment,
                     state_before=sorted({s for s, _ in before}), state_after=sorted({s for s, _ in after}),
                     rInterrupt_before=sorted({i for _, i in before}), rInterrupt_after=sorted({i for _, i in after}),
                     inferred_enT3_values=sorted(en3), grp1LatchEn_from_observed_micro=group1,
                     predicted_update_values=sorted(update), intPend_observed_before=row['intPend_before'],
                     microLatch_observed_before=word,
                     possible_microaddresses=[a for a, v in enumerate(micro) if v == word],
                     observed_pc_before=(row['PcH_before'] << 16) | row['PcL_before'],
                     label='Source/state-set inference; rInterrupt and enT3 were not observed ports.')
        derived.append(entry)
        if update == {1}:
            updates.append(entry)
        states, previous = after, row['tick']
    cases = []
    for case in timeline['known_field59_relocated_write_cases']:
        start, stop = case['assertion']['tick'], case['iack']['tick']
        matches = [x for x in updates if start <= x['tick'] <= stop and x['intPend_observed_before'] == 1]
        cases.append(dict(assertion=case['assertion'], actual_iack=case['iack'],
                          actual_tile_write=case['tile_write'],
                          first_uniquely_predicted_pending_group1_update=matches[0] if matches else None,
                          dispatch_observed=False, dispatch_proven=False))
    private = ROOT / 'sim/captures/diagnostics/irq_ipl_recognition61_state_join'
    private.mkdir()
    csvpath = private / 'derived_states.csv'
    with csvpath.open('x', encoding='utf-8', newline='') as f:
        names = ['tick', 'frame', 'segment', 'state_before', 'state_after', 'rInterrupt_before', 'rInterrupt_after',
                 'inferred_enT3_values', 'grp1LatchEn_from_observed_micro', 'predicted_update_values',
                 'intPend_observed_before', 'microLatch_observed_before', 'possible_microaddresses', 'observed_pc_before']
        writer = csv.DictWriter(f, fieldnames=names)
        writer.writeheader()
        for x in derived:
            writer.writerow({k: json.dumps(x[k]) if isinstance(x[k], list) else x[k] for k in names})
    result = dict(scope='Finite conservative joint(tState,rInterrupt) state-set join of actual immutable observations. No replay.',
                  source_lines=dict(enT1_enT3_enT4=[178, 181], tState_FSM=[185, 197], group1_latch=[2107, 2109, 2126, 2128]),
                  pins={str(p): sha(p) for p in [FX / 'fx68k.sv', FX / 'microrom.mem', C / 'ipl_phase.csv', C / 'instruction_events.csv', timeline_path]},
                  analyzer_sha256=sha(Path(__file__)), derived_csv_path=str(csvpath), derived_csv_sha256=sha(csvpath),
                  rows=len(rows), contiguous_segments=segment + 1, inconsistent_rows=violations,
                  ambiguous_tState_before_rows=sum(len(x['state_before']) != 1 for x in derived),
                  ambiguous_enT3_rows=sum(len(x['inferred_enT3_values']) != 1 for x in derived),
                  ambiguous_rInterrupt_before_rows=sum(len(x['rInterrupt_before']) != 1 for x in derived),
                  uniquely_enabled_group1_updates=len(updates), known_write_cases=cases,
                  state_join_consistent=not violations,
                  both_known_cases_have_unique_predicted_pending_latch=all(x['first_uniquely_predicted_pending_group1_update'] is not None for x in cases),
                  labels=['enT3 and rInterrupt are inferred, not directly captured.',
                          'Each gap starts with all five tStates and both rInterrupt values; no initial state/dispatch is fabricated.',
                          'Unknown wait state is constrained only by observed enT1/enT4; no phase patch or CPU correction.',
                          'Group-one assignment at a unique inferred enable is source-predicted. Architectural dispatch and MAME cutoff remain unproven.'],
                  nanocode_comparison_receipt='research/irq_fx_mame_nanocode_comparison.json',
                  import_safety_receipt='research/irq_ipl_recognition61_import_safety.json',
                  dispatch_proven=False, B16_closed=False, physical_cause_proven=False, timing_fix_proven=False)
    write('irq_ipl_recognition61_state_join.json', result)
    md = R / 'irq_ipl_recognition61_state_join.md'
    with md.open('x', encoding='utf-8') as f:
        f.write('# Finite interrupt state-set join\n\nNo replay. Each contiguous observation segment starts with all five tStates and both possible rInterrupt values. The exact pinned FSM plus observed enables constrains this joint state set; ambiguity remains explicit. enT3/rInterrupt are source-derived inference, not captured ports or observed dispatch.\n\n')
        f.write('Rows: '+str(len(rows))+'. Consistency violations: '+str(len(violations))+'. Unique enabled group-one assignments: '+str(len(updates))+'.\n\n')
        for x in cases:
            match = x['first_uniquely_predicted_pending_group1_update']
            f.write('Tile '+hex(x['actual_tile_write']['address'])+': first unique predicted pending group-one assignment '+str(match['tick'] if match else 'unknown')+'; actual IACK '+str(x['actual_iack']['tick'])+'.\n\n')
        f.write('Raw microcode word may map to several addresses, and nanolatch forwarding was not captured. Dispatch, MAME cutoff, B16 and physical cause/fix remain unproven. Separate receipts contain nanocode-value comparison and isolated helper-import safety.\n')
    print(json.dumps(dict(rows=len(rows), segments=segment + 1, violations=len(violations),
                          ambiguous_tState=result['ambiguous_tState_before_rows'],
                          ambiguous_enT3=result['ambiguous_enT3_rows'],
                          updates=len(updates), cases=[dict(address=hex(x['actual_tile_write']['address']),
                              predicted=x['first_uniquely_predicted_pending_group1_update']) for x in cases],
                          nano_summary={k:nano[k] for k in ['compact_words','mapped_microaddresses_compared','compact_words_covered','all_mapped_words_equal','unmapped_microaddresses']},
                          manifest_unchanged=True, receipt_sha256=sha(R / 'irq_ipl_recognition61_state_join.json'))))


if __name__ == '__main__':
    main()
