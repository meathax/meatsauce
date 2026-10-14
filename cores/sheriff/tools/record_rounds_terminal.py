# SPDX-License-Identifier: GPL-2.0-or-later
"""Record the completed real-RTL third-round replay without hiding divergence."""
import csv
import hashlib
import json
from pathlib import Path

root=Path(__file__).resolve().parents[1]
native=root/'sim/results/rounds-dac-rtl'
reference=root/'sim/results/rounds-static-mame'
receipt=root/'_checks/rounds-terminal-20261009/result.json'
scanout=json.loads((native/'terminal-scanout.json').read_text())
checkpoints=json.loads((native/'terminal-checkpoints.json').read_text())
inputs=json.loads((native/'terminal-inputs.json').read_text())
terminal=(native/'stdout.log').read_text().strip()
assert terminal.startswith('frames=12000 ')
assert scanout['checks'][-1]['frame']==12000
assert len(scanout['checks'])==204
assert all(code==0 for code in json.loads(receipt.read_text(encoding='utf-8-sig')).values())
checks=scanout['checks']
differences=[c for c in checks if c['mismatch_count']]

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def red_commands(directory):
    commands=[]
    with (directory/'io.csv').open() as f:
        for r in csv.DictReader(f):
            if r['kind'].lower()=='out' and int(r['address'])&7==6 and int(r['data'])&31==14:
                commands.append({'frame':int(r['frame']),'data':int(r['data'])})
    return commands

red_fields=[]
for path in sorted(native.glob('frame_*.ppm')):
    pixels=path.read_bytes().split(b'\n',3)[3]
    assert len(pixels)==256*224*3
    count=sum(pixels[i:i+3]==b'\xff\x00\x00' for i in range(0,len(pixels),3))
    if count:red_fields.append({'frame':int(path.stem.split('_')[1]),'red_pixels':count})

regression=json.loads((receipt.parent/'restart-streamed.json').read_text())
baseline=json.loads((root/'sim/results/restart-phase-ce-rtl/terminal-scanout.json').read_text())
assert regression['checks']==baseline['checks']
files=[root/'tools/compare_streaming_video.py',root/'tools/compare_sheriff.py',
       root/'tools/compare_input_transactions.py',Path(__file__).resolve(),
       root/'sim/inputs_rounds.csv',root/'sim/build/dac-level-fix/board/Vn8080_board',
       receipt,receipt.parent/'restart-streamed.json']
files += [native/n for n in ('stdout.log','stderr.log','terminal-scanout.json',
          'terminal-checkpoints.json','terminal-inputs.json','io.csv','memory_writes.bin')]
files += [reference/n for n in ('input_sha256.json','capture_features.json','io.csv','video_writes.csv')]
assert digest(root/'sim/inputs_rounds.csv')=='614f4f312809039ed876dedf5b80e856e8ed879f2c1bec65650ea5a6210ddc9f'
result={
    'scope':'Terminal 12000-frame ordinary-input Sheriff board replay; third-round acceptance failed',
    'source_label':json.loads((root/'docs/evidence/sheriff_integrated_dac.json').read_text())['source_label'],
    'native_capture':str(native.relative_to(root)),
    'mame_capture':str(reference.relative_to(root)),
    'terminal':terminal,'native_process_exit':None,
    'native_stderr_empty':(native/'stderr.log').stat().st_size==0,
    'scanout_comparator_exit':0,'checkpoint_comparator_exit':0,'input_comparator_exit':0,
    'native_fields':len(checks),'exact_native_fields':len(checks)-len(differences),
    'nonmatching_native_fields':len(differences),
    'different_native_pixels':scanout['total_mismatch_pixels'],
    'first_native_difference':differences[0] if differences else None,
    'bonus_reference_field_comparison':next(c for c in checks if c['frame']==11340),
    'end_frame_ram_differing_fields':sum(c['different_bytes']>0 for c in checkpoints['ram']),
    'end_frame_pixels_differing_fields':sum(c['different_pixels']>0 for c in checkpoints['pixels']),
    'raw_output_sequence':checkpoints['io'],
    'input_read_matching_prefix':inputs['matched_prefix'],
    'first_input_read_difference':inputs['first_difference'],
    'native_red_fields':red_fields,
    'red_color_commands':{'mame':red_commands(reference),'rtl':red_commands(native)},
    'streaming_comparator_regression':{'checks_identical':True,'fields':124,'different_pixels':2},
    'sha256':{str(p.relative_to(root)):digest(p) for p in files},
    'strict_graphics_gate_pass':False,'third_round_gameplay_gate_pass':False,
    'complete_sheriff_gate_pass':False,
    'limits':[
        'Native terminal frame/log verified; the original launcher did not preserve its process exit code',
        'Timed MAME write scanout is a functional model; physical DRAM/74198 byte-fetch timing is still open',
        'The reference reaches the third-round bonus; fixed-input native replay diverges before it',
        'No pixel, input, RAM, output or IRQ mismatch is waived',
        'These board captures do not qualify the full MiSTer wrapper or current-source timing',
        'Quartus remains prohibited until the user explicitly resumes it']}
destination=root/'docs/evidence/sheriff_rounds_native_terminal.json'
destination.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'report':str(destination.relative_to(root)),
    'native_fields':len(checks),'exact_native_fields':result['exact_native_fields'],
    'different_pixels':scanout['total_mismatch_pixels'],
    'native_red_fields':len(red_fields),
    'red_commands':{side:len(rows) for side,rows in result['red_color_commands'].items()}}))
