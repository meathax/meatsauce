#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Record the actual protocol direction test for the production control adapter."""
import hashlib
import json
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    root = Path('_checks/controls-protocol-20261010')
    receipt = json.loads((root / 'receipt.json').read_text())
    assert receipt['exit_code'] == 0
    assert 'PASS: two independent players' in (root / 'run.stdout.log').read_text()
    paths = [Path(__file__), Path('rtl/n8080_controls.sv'), Path('sim/controls_qualification.cpp'),
             root / 'receipt.json', root / 'run.stdout.log', root / 'run.stderr.log',
             root / 'controls/build.log', root / 'controls/Vn8080_controls']
    mappings = [dict(direction=label, mister=mi, sheriff=sh) for label, mi, sh in zip(
        ['R', 'DR', 'D', 'DL', 'L', 'UL', 'U', 'UR'],
        [1, 5, 4, 6, 2, 10, 8, 9], [1, 9, 8, 10, 2, 6, 4, 5])]
    result = dict(scope='Production control adapter: MiSTer digital movement protocol, both players.',
                  receipt=receipt, movement_directions=mappings,
                  evidence_sha256={p.as_posix(): sha(p) for p in paths},
                  protocol_reference='https://github.com/MiSTer-devel/Main_MiSTer/blob/master/user_io.h',
                  game_reference='MAME0.289 src/mame/nintendo/n8080.cpp INPUT_PORTS_START(sheriff)',
                  change='Translate digital movement R,L,D,U to Sheriff R,L,U,D before combining keyboard/analog inputs.',
                  scoped_control_qualified=True,
                  limitations=['Component-level direction/aim/analog/keyboard/button/rotary/pause test.',
                               'Current-source HPS gameplay and exact-source fit/STA/resource checks are separate.',
                               'Bare-board frozen input scenarios bypass this adapter and remain valid.'],
                  release_qualified=False, rbf_built=False)
    output = Path('docs/evidence/sheriff_controls_protocol.json')
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(unit_exit=0, digital_movement_directions=8, players=2,
                          report=output.as_posix())))


if __name__ == '__main__':
    main()
