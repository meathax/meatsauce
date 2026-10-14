#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Locate the first two-player cocktail turn in an unchanged MAME capture."""
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    root = Path('sim/results/cocktail-reference-mame-20261010')
    inputs = Path('sim/inputs/sheriff_cocktail_two_player.csv')
    expected_hash = '93df2be1a9e143b9daff0c9176ee07d7c77e7e15fe94bda44630177d253eb6c4'
    assert sha(inputs) == expected_hash
    receipt = json.loads((root / 'exit.json').read_text(encoding='utf-8-sig'))
    assert receipt['exit_code'] == 0 and receipt['frames_requested'] == 8000
    assert receipt['lua_sha256'].lower() == sha(Path('sim/mame_capture.lua'))
    assert receipt['launcher_sha256'].lower() == sha(Path('tools/mame_capture.ps1'))
    assert json.loads((root / 'input_sha256.json').read_text(encoding='utf-8-sig'))['Hash'].lower() == expected_hash
    exe_hash = sha(Path('D:/Arcade/AI/mameexe/mame.exe'))
    assert exe_hash == 'af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'
    flip, transitions, first_p2 = None, [], None
    p2_values, shared_input_reads = {}, {}
    with (root / 'io.csv').open(newline='') as stream:
        for row in csv.DictReader(stream):
            port, data = int(row['address']) & 7, int(row['data'])
            event = {k: row[k] for k in ('time', 'frame', 'data', 'pc')}
            if row['kind'] == 'out' and port == 6 and (data & 32) != flip:
                flip = data & 32
                transitions.append(event)
            if row['kind'] == 'in' and port == 1 and data:
                first_p2 = first_p2 or event
                p2_values[str(data)] = p2_values.get(str(data), 0) + 1
            if row['kind'] == 'in' and port == 2:
                shared_input_reads[str(data)] = shared_input_reads.get(str(data), 0) + 1
    assert int(transitions[1]['frame']) == 4207 and int(transitions[1]['data']) & 32
    assert int(first_p2['frame']) == 4339
    assert set(map(int, p2_values)) == {17, 81, 84, 68, 66, 98, 104, 40, 161, 129, 132, 148, 146, 18}
    report = {
        'scope': 'MAME0.289 parent Sheriff, deterministic three-life cocktail/two-player scenario; native qualification pending.',
        'mame_receipt': receipt,
        'inputs': {'path': inputs.as_posix(), 'sha256': expected_hash,
            'stimulus': 'Two coin pulses600/610; Start2 at690; P1 idle; P2 fourteen movement/aim combinations with fire pulses from1000.'},
        'mame_exe_sha256': exe_hash,
        'flip_bit_transitions': transitions,
        'first_nonzero_p2_control_read': first_p2,
        'p2_nonzero_input_read_counts': p2_values,
        'shared_input_read_counts': shared_input_reads,
        'next_native_stop_field': 4801,
        'evidence_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), root / 'exit.json',
            root / 'io.csv', root / 'video_writes.csv', root / 'audio.wav']},
        'limitations': ['Reference preparation only; no native P2/cocktail graphics or gameplay pass.',
            'Port6 flip transition is software output evidence; physical RAM/serializer phase remains open.',
            'First P2 turn does not establish complete two-player lifecycle, mixed audio or release readiness.'],
        'native_cocktail_qualified': False, 'release_qualified': False, 'rbf_built': False}
    output = Path('docs/evidence/sheriff_cocktail_reference.json')
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'mame_exit': receipt['exit_code'], 'first_flip_field': 4207,
        'first_nonzero_p2_read_field': 4339, 'nonzero_p2_values': len(p2_values),
        'next_native_stop_field': 4801, 'report': output.as_posix()}))


if __name__ == '__main__':
    main()
