#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Explain the first shared-input discrepancy without shifting either producer."""
import csv
import json
from pathlib import Path
from record_current_gameplay import sha, prefix_equal


def main():
    root = Path('sim/results/cocktail-input-boundary-mame-20261010')
    reference = Path('sim/results/cocktail-reference-mame-20261010')
    receipt = json.loads((root / 'exit.json').read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 3802
    assert receipt['lua_sha256'].lower() == sha(Path('sim/mame_capture.lua'))
    assert receipt['launcher_sha256'].lower() == sha(Path('tools/mame_capture.ps1'))
    assert prefix_equal(root / 'io.csv', reference / 'io.csv')
    with (root / 'input_observations.csv').open(newline='') as stream:
        rows = list(csv.DictReader(stream))
    pivot = next(i for i, row in enumerate(rows)
                 if row['kind'] == 'apply' and row['event_frame'] == '3800')
    old, change, new = rows[pivot-1:pivot+2]
    assert old['kind'] == new['kind'] == 'in'
    assert old['address'] == new['address'] == '2'
    assert old['data'] == '0' and change['p2'] == new['data'] == '1'
    assert int(old['sequence']) < int(change['sequence']) < int(new['sequence'])
    assert float(old['time']) > float(change['time'])
    cocktail = Path('docs/evidence/sheriff_current_cocktail.json')
    negative = json.loads(cocktail.read_text())['input_read_differences']['2']
    assert negative['matching_value_prefix_length'] == 11044
    native = negative['native_context'][2]
    assert native['data'] == '1' and int(native['frame']) == 3800
    assert int(native['tick']) / 50400000 > float(change['time'])
    paths = [Path(__file__), root / 'exit.json', root / 'input_observations.csv',
             root / 'io.csv', cocktail, Path('sim/board_harness.cpp'),
             Path('sim/mame_capture.lua'), Path('tools/mame_capture.ps1')]
    result = dict(scope='First shared-input read discrepancy in the finite cocktail scenario.',
                  receipt=receipt, unchanged_reference_IO_prefix=True,
                  reference_event_order=dict(read_before_callback=old,
                                             input_callback=change, read_after_callback=new),
                  native_read=native,
                  CPU_local_time_ahead_of_input_callback_master_clocks=
                      (float(old['time']) - float(change['time'])) * 50400000,
                  explanation='MAME dispatches a CPU-local future I/O read before the frame callback updates the external input. Native samples the updated pin after the raster boundary.',
                  evidence_sha256={p.as_posix(): sha(p) for p in paths},
                  first_difference_explained=True,
                  limitations=['One callback-ordering boundary; not a complete CPU/RAM/I/O qualification.',
                               'No RTL offset, stream realignment or altered frozen inputs applied.',
                               'Captured-field graphics results retain their original finite scope.'],
                  release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_cocktail_input_boundary.json')
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(mame_exit=0, reference_IO_prefix=True,
                          first_difference_explained=True, report=output.as_posix())))


if __name__ == '__main__':
    main()
