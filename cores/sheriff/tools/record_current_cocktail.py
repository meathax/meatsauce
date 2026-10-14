#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind the finite current-source cocktail replay to independent MAME evidence."""
import csv
import json
from pathlib import Path
from record_current_gameplay import sha


def controls(path, last_field):
    flip, first_p2 = None, None
    transitions, values, shared = [], {}, {}
    with path.open(newline='') as stream:
        for row in csv.DictReader(stream):
            if int(row['frame']) > last_field:
                continue
            port, data = int(row['address']) & 7, int(row['data'])
            if row['kind'] == 'out' and port == 6 and data & 32 != flip:
                flip = data & 32
                transitions.append(row)
            if row['kind'] == 'in' and port == 1 and data:
                first_p2 = first_p2 or row
                values[str(data)] = values.get(str(data), 0) + 1
            if row['kind'] == 'in' and port == 2:
                shared[str(data)] = shared.get(str(data), 0) + 1
    return dict(flip_transitions=transitions, first_p2_read=first_p2,
                p2_read_counts=values, shared_read_counts=shared)


def read_sequence(path, port, last_field):
    with path.open(newline='') as stream:
        return [row for row in csv.DictReader(stream) if row['kind'] == 'in'
                and int(row['address']) & 7 == port and int(row['frame']) <= last_field]


def read_difference(native, reference):
    first = next((i for i, (a, b) in enumerate(zip(native, reference))
                  if a['data'] != b['data']), min(len(native), len(reference)))
    return dict(native_count=len(native), reference_count=len(reference),
                matching_value_prefix_length=first,
                value_difference_in_common_prefix=first < min(len(native), len(reference)),
                native_context=native[max(0, first-2):first+3],
                reference_context=reference[max(0, first-2):first+3])


def main():
    check = Path('_checks/current-cocktail-4801-20261010')
    terminal = check / 'terminal-v2.json'
    native_exit = json.loads(terminal.read_text(encoding='utf-8-sig'))
    assert native_exit['exit_code'] == 0 and native_exit['frames_requested'] == 4801
    assert not native_exit['source_changed_during_run']
    assert sha(Path(native_exit['model'])) == native_exit['model_sha256']
    assert sha(Path(native_exit['inputs'])) == native_exit['inputs_sha256']
    for name, digest in native_exit['source_sha256'].items():
        assert sha(Path(name)) == digest
        assert sha(Path('_checks/current-board-boot-20261010/sources') / name) == digest
    watch_receipt = check / 'watch-receipt.json'
    assert json.loads(watch_receipt.read_text(encoding='utf-8-sig'))['exit_code'] == 0
    comparison_path = check / 'progressive-comparison.json'
    comparison = json.loads(comparison_path.read_text())
    expected = [1, 2, 3, 4] + list(range(60, 4801, 60)) + [4801]
    assert [c['frame'] for c in comparison['checks']] == expected
    assert comparison['total_mismatch_pixels'] == 0
    assert comparison['reference_uses_fpga_ram_or_pixels'] is False
    native = Path(native_exit['runtime_output'])
    reference = Path('sim/results/cocktail-reference-mame-20261010')
    ref_report = Path('docs/evidence/sheriff_cocktail_reference.json')
    ref = json.loads(ref_report.read_text())
    assert ref['mame_receipt']['exit_code'] == 0
    assert ref['inputs']['sha256'] == native_exit['inputs_sha256']
    for name, digest in ref['evidence_sha256'].items():
        assert sha(Path(name)) == digest
    observed = {label: controls(root / 'io.csv', 4801)
                for label, root in [('native', native), ('mame', reference)]}
    for data in observed.values():
        assert int(data['flip_transitions'][1]['frame']) == 4207
        assert int(data['flip_transitions'][1]['data']) & 32
        assert int(data['first_p2_read']['frame']) == 4339
        assert set(map(int, data['p2_read_counts'])) == {
            17, 81, 84, 68, 66, 98, 104, 40, 161, 129, 132, 148, 146, 18}
    differences = {str(port): read_difference(read_sequence(native / 'io.csv', port, 4801),
                                             read_sequence(reference / 'io.csv', port, 4801))
                   for port in (1, 2)}
    assert not differences['1']['value_difference_in_common_prefix']
    assert differences['1']['matching_value_prefix_length'] == 421
    # Preserve the observed shared-input difference; do not realign or waive it.
    assert differences['2']['value_difference_in_common_prefix']
    assert differences['2']['matching_value_prefix_length'] == 11044
    paths = [Path(__file__), terminal, watch_receipt, comparison_path, ref_report,
             native / 'io.csv', native / 'memory_writes.bin', native / 'sound.csv']
    report = dict(scope='Current bare board through first P2 cocktail turn, field4801; 85 exported fields.',
                  native_receipt=native_exit, source_closure_verified=True,
                  mame_reference=ref_report.as_posix(), timed_MAME_scanout=comparison,
                  observed_controls=observed, input_read_differences=differences,
                  captured_cocktail_video_qualified=True, input_read_equivalence_qualified=False,
                  evidence_sha256={p.as_posix(): sha(p) for p in paths},
                  limitations=['Stored reference and captured fields; no all-domain live lockstep qualification.',
                               'Complete two-player lifecycle, round/bonus/game-over/restart and mixed audio remain open.',
                               'Full-wrapper hostile boot and final-source fit/STA/resource gates remain open.',
                               'Shared input values first diverge at ordinal11044 near the field3800 boundary.',
                               'MAME includes later field4801 reads beyond the native stop; counts are retained without trimming.',
                               'Physical RAM/READY/serializer and absolute CPU/raster phase remain unqualified.'],
                  full_gameplay_gate_qualified=False, release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_current_cocktail.json')
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(native_exit=0, captured_fields=len(expected), pixel_differences=0,
                          first_flip_field=4207, first_p2_read_field=4339,
                          first_shared_input_difference_ordinal=11044,
                          input_read_equivalence_qualified=False, report=output.as_posix())))


if __name__ == '__main__':
    main()
