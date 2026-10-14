"""Bounded observed gameplay device coverage; raw captures remain local."""
from pathlib import Path
import csv,json,collections,hashlib
root=Path(__file__).resolve().parents[1]
summaries={}
for folder in ('mame-play-1800-play-2p','mame-play-900-play-4p'):
    base=root/'sim/results'/folder
    result={}
    for name in ('cop-events','sound-events'):
        with (base/(name+'.csv')).open() as f:rows=list(csv.DictReader(f))
        counts=collections.Counter(int(r['address']) for r in rows)
        commands=collections.Counter(int(r['data']) for r in rows if 0x500<=int(r['address'])<=0x505)
        result[name]={'events':len(rows),'bounded_capture_truncated':len(rows)>=50000,
                      'addresses':{hex(k):v for k,v in sorted(counts.items())},
                      'cop_commands':{hex(k):v for k,v in sorted(commands.items())},
                      'trace_sha256':hashlib.sha256((base/(name+'.csv')).read_bytes()).hexdigest()}
    result['input_events']=sum(1 for _ in (base/'input-events.csv').open())-1
    result['image_sha256']=hashlib.sha256((base/'reference.png').read_bytes()).hexdigest()
    summaries[folder]=result
meta={'scope':'Pristine MAME physical-input play references, not RTL gameplay verification',
      'references':summaries,
      'observed_images':{'mame-play-1800-play-2p':'Player in a scrolling first-stage scene, score 6000, time 58',
                         'mame-play-900-play-4p':'Four player HUDs present with 4P/4-slot cabinet setting'},
      'limits':['MAME marks this driver not working; sort/priority gaps remain.',
                'No first-stage completion or natural progression is inferred from a frame limit.',
                'No game RAM, ROM or CPU state is injected by the playback helper.']}
(root/'docs/evidence/mame-play-device-coverage.json').write_text(json.dumps(meta,indent=2)+'\n')
for name,r in summaries.items():
    print(json.dumps({'reference':name,'cop_events':r['cop-events']['events'],
                      'cop_commands':r['cop-events']['cop_commands'],'sound_events':r['sound-events']['events'],
                      'oki_writes':r['sound-events']['addresses'].get('0x6000',0)}))
