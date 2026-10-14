"""Check that debug RAM observations preserve the same core's execution.

Both inputs must use identical RTL, ROM and controller stimulus; this is a
pause/service integrity check, not an independent game-hardware reference.
"""
import argparse
import hashlib
import json
import struct
from collections import deque
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--observed',type=Path,required=True)
p.add_argument('--unobserved',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
checks={}
for name in ('memory_writes.bin','io.csv','sound.csv','audio.raw'):
    files=[a.observed/name,a.unobserved/name]
    hashes=[hashlib.sha256(f.read_bytes()).hexdigest() for f in files]
    checks[name]={'equal':hashes[0]==hashes[1],
        'observed_bytes':files[0].stat().st_size,'unobserved_bytes':files[1].stat().st_size,
        'observed_sha256':hashes[0],'unobserved_sha256':hashes[1]}
first=None;history=deque(maxlen=5);index=0
with (a.observed/'memory_writes.bin').open('rb') as left,(a.unobserved/'memory_writes.bin').open('rb') as right:
    while True:
        raw_left,raw_right=left.read(11),right.read(11)
        if not raw_left and not raw_right:break
        event={}
        for name,raw in (('observed',raw_left),('unobserved',raw_right)):
            if len(raw)==11:
                tick,address,data=struct.unpack('<QHB',raw)
                event[name]={'tick':tick,'address':hex(address),'data':data}
            else:event[name]=None
        if raw_left!=raw_right:
            first={'index':index,'before':list(history),'actual':event};break
        history.append(event);index+=1
checks['native_frames']={'equal':True,'frames':[]}
for file in sorted(a.observed.glob('frame_*.ppm')):
    other=a.unobserved/file.name
    equal=other.exists() and file.read_bytes()==other.read_bytes()
    checks['native_frames']['frames'].append({'frame':file.stem,'equal':equal})
    checks['native_frames']['equal'] &= equal
report={'scope':'Debug observation integrity on identical real RTL and stimulus',
    'observed':str(a.observed),'unobserved':str(a.unobserved),'checks':checks,
    'first_memory_difference':first,'pass':all(c['equal'] for c in checks.values())}
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
raise SystemExit(0 if report['pass'] else 1)
