# SPDX-License-Identifier: GPL-2.0-or-later
"""Freeze terminal native-video evidence, retaining unresolved differences."""
import hashlib
import json
from pathlib import Path

root=Path(__file__).resolve().parents[1]
captures=[]
for name,frames in [('restart',7200),('cocktail',6000)]:
    directory=root/'sim/results'/f'{name}-phase-ce-rtl'
    terminal=(directory/'stdout.log').read_text()
    assert terminal.startswith(f'frames={frames} '), 'Replay is not terminal'
    scanout=json.loads((directory/'terminal-scanout.json').read_text())
    checkpoints=json.loads((directory/'terminal-checkpoints.json').read_text())
    checks=scanout['checks']
    assert checks[-1]['frame']==frames, 'Final checkpoint is missing'
    mismatches=[row for row in checks if row['mismatch_count']]
    captures.append({'name':name,'frames':frames,'rtl_capture':str(directory),
        'mame_capture':str(root/'sim/results'/f'{name}-mame'),
        'terminal':terminal.strip(),'native_frames_compared':len(checks),
        'native_mismatch_pixels':sum(row['mismatch_count'] for row in checks),
        'native_mismatches':mismatches,
        'end_frame_ram_mismatches':sum(row['different_bytes']>0 for row in checkpoints['ram']),
        'end_frame_pixels_mismatches':sum(row['different_pixels']>0 for row in checkpoints['pixels']),
        'raw_output_sequence':checkpoints['io'],
        'evidence_sha256':{file:hashlib.sha256((directory/file).read_bytes()).hexdigest()
            for file in ('terminal-scanout.json','terminal-checkpoints.json','stdout.log')}})
report={'scope':'Terminal restart/cocktail native scanout diagnostics',
    'hardware_revision':'0b24750fa6b395fc715844b9a36a2d1acca9bf03',
    'elf':'sim/build/service-ce-final/board/Vn8080_board',
    'captures':captures,'complete_simulation_gate_pass':False,
    'limits':['Two restart pixels remain unresolved; no tolerance or waiver is applied',
        'Raw I/O sequences and end-frame snapshots retain their differences',
        'These captures precede the downstream DAC mixer correction; they do not qualify final audio',
        'MAME end-frame images and live scanout are separate observations']}
destination=root/'docs/evidence/sheriff_native_long_captures.json'
destination.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'report':str(destination),'captures':[{
    'name':c['name'],'frames':c['frames'],'native_frames':c['native_frames_compared'],
    'mismatch_pixels':c['native_mismatch_pixels']} for c in captures]}))
