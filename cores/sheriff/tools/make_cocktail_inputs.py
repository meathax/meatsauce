#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reproduce the locally staged, hash-bound Sheriff cocktail stimulus."""
import hashlib
from pathlib import Path

path = Path('sim/inputs/sheriff_cocktail_two_player.csv')
rows = [(0, 0, 0, 0, 124), (600, 0, 0, 128, 124), (605, 0, 0, 0, 124),
        (610, 0, 0, 128, 124), (615, 0, 0, 0, 124), (690, 0, 0, 8, 124),
        (750, 0, 0, 0, 124)]
moves = [17, 81, 84, 68, 66, 98, 104, 40, 161, 129, 132, 148, 146, 18]
rows.extend((frame, 0, moves[((frame - 1000) // 24) % len(moves)],
             int(((frame - 1000) // 4) % 2 == 0), 124)
            for frame in range(1000, 8001, 4))
text = 'frame,p0,p1,p2,dip\n' + ''.join(','.join(map(str, row)) + '\n' for row in rows)
# Preserve the original Windows CSV bytes independently of the host's newline mode.
data = text.replace('\n', '\r\n').encode('ascii')
digest = '93df2be1a9e143b9daff0c9176ee07d7c77e7e15fe94bda44630177d253eb6c4'
assert hashlib.sha256(data).hexdigest() == digest
if path.exists():
    assert path.read_bytes() == data, 'Existing frozen stimulus differs; do not overwrite'
else:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
print(f'{path.as_posix()} sha256={digest} rows={len(rows)}')
