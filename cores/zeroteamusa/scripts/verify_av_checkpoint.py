"""One focused uninterrupted/resumed proof of real RTL checkpoint fidelity."""
from pathlib import Path
import json,hashlib
root=Path(__file__).resolve().parents[1]
results=root/'sim/results'
a=json.loads((results/'board-avcheckpoint-base-boot.json').read_text())
b=json.loads((results/'board-avcheckpoint-resume-boot.json').read_text())
assert a==b,'Board/device/bridge counts differ after restore'
assert a['cycles']==200000
checks={}
for name in ('bg','fg','mg','text','palette','sprite','workram'):
    left=(results/f'board-avcheckpoint-base-{name}.bin').read_bytes()
    right=(results/f'board-avcheckpoint-resume-{name}.bin').read_bytes()
    assert left==right,name
    checks[name]={'bytes':len(left),'sha256':hashlib.sha256(left).hexdigest()}
assert (results/'rtl-live-logocheckpoint-base.ppm').read_bytes()==(results/'rtl-live-logocheckpoint-resume.ppm').read_bytes()
stamp=json.loads((results/'avcheckpoint-base-checkpoint-100000.json').read_text())
meta={'scope':'Real RTL model plus all external ROM bridges/capture counters saved at cycle 100000, continued to cycle 200000',
      'result':'Uninterrupted and restored report, seven RAM ranges and final image are exactly equal',
      'buffers':checks,'report':a,'build_inputs':stamp,
      'limits':['Short cold-boot bridge/CPU continuation proof, not a game-completion proof.',
                'Long-run checkpoints include the same model/bridge fields; post-attract continuation remains to be exercised.',
                'Checkpoint streams contain private ROM/RAM data and stay ignored/local.',
                'This is a Verilator diagnostic checkpoint, not a finished MiSTer user savestate.']}
(root/'docs/evidence/av-checkpoint-roundtrip.json').write_text(json.dumps(meta,indent=2)+'\n')
print('Exact uninterrupted/resumed equality: board/device counts, 7 RAM ranges, final image')
