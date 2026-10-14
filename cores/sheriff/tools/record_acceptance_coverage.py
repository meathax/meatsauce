#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind remaining Sheriff acceptance to retained, immutable input fixtures.

This checks fixture identity/coverage metadata; it never runs a CPU, emulator,
compiler or deployment, and never converts evidence into a gameplay pass.
"""
import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def load(name):
    return json.loads((ROOT / 'docs/evidence' / name).read_text(encoding='utf-8'))

def fixture(name, path, expected_hash, evidence, checkpoints, next_action):
    file = ROOT / path
    actual = digest(file)
    assert actual == expected_hash.lower(), f'{name}: frozen input changed'
    with file.open(encoding='utf-8', newline='') as handle:
        reader = csv.DictReader(handle)
        assert reader.fieldnames == ['frame', 'p0', 'p1', 'p2', 'dip']
        events = [{k: int(v) for k, v in row.items()} for row in reader]
    assert events and events[0]['frame'] == 0
    assert all(a['frame'] <= b['frame'] for a,b in zip(events,events[1:]))
    assert all(0 <= e[k] <= 255 for e in events for k in ['p0','p1','p2','dip'])
    return {
        'id': name, 'path': path, 'sha256': actual,
        'events': len(events), 'last_input_field': events[-1]['frame'],
        'initial_levels': events[0],
        'dip_values': sorted({e['dip'] for e in events}),
        'raw_control_values': {k: sorted({e[k] for e in events}) for k in ['p0','p1','p2']},
        'evidence': evidence, 'checkpoints': checkpoints,
        'next_action': next_action,
        'final_current_wrapper_acceptance': False,
    }

def main():
    bridge = load('sheriff_gameplay_source_bridge.json')
    rounds = load('sheriff_rounds_reference.json')
    cocktail = load('sheriff_cocktail_reference.json')
    gain = load('sheriff_current_gain_integration.json')
    native_rounds = load('sheriff_rounds_native_terminal.json')
    current_p2 = load('sheriff_current_cocktail.json')
    restart = bridge['saved_native_terminal']
    assert restart['exit_code'] == 0 and restart['frames_requested'] == 6781
    assert cocktail['mame_receipt']['exit_code'] == 0
    assert rounds['frames'] == 12000 and rounds['normal_lives_dip'] == 6
    assert rounds['first_red_color_frame'] == 11302
    assert gain['scoped_gain_integration_qualified'] is True
    assert gain['full_gameplay_gate_qualified'] is False
    assert gain['full_audio_gate_qualified'] is False
    assert gain['full_graphics_gate_qualified'] is False
    assert current_p2['input_read_equivalence_qualified'] is False

    cases = [
        fixture('p1_restart', restart['inputs'], restart['inputs_sha256'],
                ['sheriff_gameplay_source_bridge.json', 'sheriff_gameplay_lifecycle.json',
                 'sheriff_clock_restart6780.json', 'sheriff_lifecycle_ram_boundaries.json'],
                {'attract':600, 'ready':780, 'game_over_observations':[6060,6120],
                 'restart_coin':6200, 'restart_start':6290, 'restart_play':6780,
                 'unresolved_pixel_field':2760, 'preceding_bus_fields':[2758,2759]},
                'Reuse saved lifecycle/source bridge. Resolve the first pixel/IRQ/memory boundary before a new full-wrapper lifecycle run.'),
        fixture('p1_later_rounds', rounds['input_file'], rounds['input_sha256'],
                ['sheriff_rounds_reference.json','sheriff_rounds_native_terminal.json',
                 'sheriff_clock_round2400.json'],
                {'reference_fields':12000, 'first_red_control':11302,
                 'red_pixels_checkpoint':11340,
                 'historical_native_negative_is_final_acceptance':False},
                'Preserve six-life reference. Check earliest affected boundary first; extend the corrected executable only after it passes, through red control/pixel checkpoints.'),
        fixture('p2_cocktail', cocktail['inputs']['path'], cocktail['inputs']['sha256'],
                ['sheriff_cocktail_reference.json','sheriff_current_cocktail.json',
                 'sheriff_cocktail_input_boundary.json'],
                {'reference_fields':cocktail['mame_receipt']['frames_requested'],
                 'first_p2_control_read':int(cocktail['first_nonzero_p2_control_read']['frame']),
                 'saved_native_stop':4801,
                 'shared_input_equivalence':False},
                'Reuse the first-P2 comparison. Qualify the actual current full wrapper and required second-player lifecycle; do not label the 4801-field prefix a complete cocktail game.'),
    ]
    assert len({c['sha256'] for c in cases}) == 3, 'Do not conflate distinct scenarios'
    assert cases[0]['dip_values'] == [252]
    assert cases[1]['dip_values'] == [255]
    evidence_names = sorted({n for c in cases for n in c['evidence']} | {
        'sheriff_current_gain_integration.json', 'sheriff_current_wrapper_centered_gameplay.json',
        'sheriff_reset_startup.json', 'sheriff_quartus_snapshot.json',
    })
    for name in evidence_names:
        assert (ROOT/'docs/evidence'/name).is_file(), name

    # The older exploratory cocktail file is not the qualified P2 fixture.
    exploratory = ROOT/'sim/inputs_cocktail.csv'
    excluded = {'path':'sim/inputs_cocktail.csv', 'sha256':digest(exploratory),
                'reason':'Distinct earlier fixture; do not substitute for the qualified two-player recording.'}
    assert excluded['sha256'] != cases[2]['sha256']
    result = {
        'scope':'Acceptance fixture identity and minimum campaign routing only; no new simulation pass.',
        'generator_sha256':digest(Path(__file__)),
        'cases':cases, 'excluded_fixture':excluded,
        'evidence_sha256':{n:digest(ROOT/'docs/evidence'/n) for n in evidence_names},
        'coverage_rules':[
            'Each checkpoint remains attached to its original DIP/input fixture and captured source scope.',
            'First-P2 prefix does not close both-player game-over/restart or I/O equivalence.',
            'Three-life restart evidence does not prove the six-life later-round scenario.',
            'Use one executable per current source/profile and collect journals, RGB/RAM/audio together.',
            'Existing positives are reused; first negatives and uncovered requirements select new runs.',
            'Final MAME_EXACT/full-wrapper acceptance uses the admitted harness contract and actual exits.',
        ],
        'uncovered_final_requirements':[
            'Physical raster/serializer/DRAM/READY integration and field2760 mismatch closure.',
            'Current native later-round red/color acceptance.',
            'Current full-wrapper complete P1/P2 lifecycle, shared-input ordering and flip.',
            'Complete mixed sound/enable/retrigger acceptance.',
            'DIPs, alternate input paths, pause/highscore, video/platform features and validated MRA.',
            'Current full-framework timing/resources, then conditional final build and hardware acceptance.',
        ],
        'native_rounds_negative_scope':native_rounds['scope'],
        'board_or_wrapper_simulation_run':False,
        'complete_sheriff':False, 'quartus_executed':False, 'rbf_built':False,
    }
    out=ROOT/'docs/evidence/sheriff_acceptance_coverage.json'
    out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='')
    doc="""# Sheriff acceptance fixture map

This selects retained fixtures for the remaining acceptance work; it proves input identity, not gameplay. Generated by `tools/record_acceptance_coverage.py`; hashes and exact bindings are in `evidence/sheriff_acceptance_coverage.json`. Follow `../plan.md` for gates and execution order.

| Frozen case | Initial DIP | Reuse / required next observation |
|---|---|---|
| P1 restart, `_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv` | 252 (0xfc), standard three-life recording | Saved attract600/ready780/game-over6060–6120/restart6780; resolve pixel2760 with preceding2758/2759 bus evidence before extending a current wrapper run. |
| P1 later rounds, `sim/inputs_rounds.csv` | 255 (0xff), six-life recording | Retain MAME12000-field baseline and historical native negative. After the first affected boundary passes, reach red command14 at11302 and pixel checkpoint11340. |
| P2 cocktail, `sim/inputs/sheriff_cocktail_two_player.csv` | See generated manifest | Retain MAME8000-field reference and scoped native4801 prefix; first P2 read4339. Complete current wrapper/lifecycle and shared-input equivalence remain open. |

The earlier `sim/inputs_cocktail.csv` is a different fixture. Do not silently substitute it, splice restart and six-life checkpoints, or reuse a main-board source bridge as current complete-wrapper acceptance.

Do not rerun the unchanged CPU/reset benches, short boot/P1-control positives, first-P2 prefix or completed mono1/gain integration. Reuse their recorded scopes. Select a new run only for the changed source, first failure or uncovered requirement; build one executable per relevant source/profile and capture CPU/RAM/I/O/IRQ/RGB/audio together. Stop a failing long scenario at its first mismatch; extend a repaired scenario rather than replaying an already known failure to12000 fields.

This map does not yet supply complete P2 game-over/restart, later-round native correctness, full mixed sound or all platform feature evidence. If the retained P2 reference lacks a required state, create only the missing ordinary-input suffix/reference after its preceding scenario is working. Final comparison remains subject to the current admitted MAME-diff/preflight contract and actual process exits. Timing/resource acceptance and the conditional final RBF/hardware phase are separate.
"""
    (ROOT/'docs/SIM_ACCEPTANCE_COVERAGE.md').write_text(doc,encoding='utf-8',newline='')
    print(json.dumps({'fixture_identity_checks':3,'cases':[{k:c[k] for k in ['id','events','dip_values','sha256']} for c in cases],
                      'manifest':str(out),'simulation_run':False,'complete_sheriff':False}))

if __name__=='__main__': main()
