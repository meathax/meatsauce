"""Read-only terminal consumer: distinguish precommit tap state from committed score."""
from pathlib import Path
import csv,json,hashlib
HERE=Path(__file__).resolve().parent/'stingray_route1800/firsthit_reference_v1'
CAP=HERE/'capture'
def pin(p):return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
assert pin(HERE/'terminal_import_manifest.json')['sha256']=='a71edf894ba8daedd4f10814dff679adc3d8442d4609f3220d96d8f626bbabfb'
memory=bytearray((CAP/'frame_000000.work.bin').read_bytes())[0x20:0x24]
points=[];changes=[]
for r in csv.DictReader((CAP/'hit_score_events.csv').open()):
 r={k:(v if k=='kind' else int(v)) for k,v in r.items()}
 if r['kind']=='actual_projectile_point_award':points.append(r);continue
 before=int.from_bytes(memory,'big')
 for lane in [0,1]:
  mask=0xff00 if lane==0 else 0xff
  if r['mask']&mask:memory[r['address']-0x20020+lane]=(r['data']>>(8 if lane==0 else 0))&255
 after=int.from_bytes(memory,'big')
 if before!=after:changes.append(dict(observed=r,precommit_BCD=before,committed_BCD=after,preceding_projectile_point_read=points[-1] if points else None))
actions=list(csv.DictReader((CAP/'legal_actions.csv').open()))
first=next(x for x in changes if x['committed_BCD']>x['precommit_BCD'] and x['observed']['curpc']==0x16aa and x['preceding_projectile_point_read'])
assert first['observed']['frame']==1008 and first['committed_BCD']==0x10
assert first['preceding_projectile_point_read']['curpc']==0x4514 and first['preceding_projectile_point_read']['address']==0x72a6 and first['preceding_projectile_point_read']['data']==0x10
assert first['observed']['ticks48m']>first['preceding_projectile_point_read']['ticks48m']
post=[r for r in actions if int(r['request_completed_field'])>186]
assert [(int(r['request_completed_field']),int(r['joystick'])) for r in post]==[(884,1),(957,24),(1009,0)]
result=dict(actual_exit=0,first_actual_score_commit=first,score_changes=changes,points_reads=points,ordered_postboot_actions=post,
 actual_route='RIGHT884..956 then UP+fire957..1008; moving target already entered the live ray so no UP-only phase was required. Release1009 after source predicate;1010fields complete.',
 points_display=100,predicate_frame=1009,
 observation_limit='Tap callbacks run before RAM commit; the score column/current_score reads retained previous work-tap state. The original Lua first_hit_frame1009 denotes detection of the retained nonzero state on the next score store, not first physical award. Ordered data/mask replay proves first genuine award/score commit1008, with source CURPC4514→16aa. Original receipts are preserved.',
 shortest_claim='Useful legal route proven in this single trial; global shortest route is not proven.',earned148=False,native_runtime=False)
p=HERE/'score_epoch_supplement.json';assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n')
m=HERE/'terminal_import_manifest_v2.json';assert not m.exists();m.write_text(json.dumps(dict(scope='Preserve original11/11 terminal; qualify first actual score commit from ordered physical tap data',original=pin(HERE/'terminal_import_manifest.json'),result=result,files=[pin(Path(__file__)),pin(p),pin(CAP/'hit_score_events.csv'),pin(CAP/'legal_actions.csv'),pin(CAP/'frame_000000.work.bin'),pin(CAP/'frame_001009.work.bin')]),indent=2)+'\n')
print(json.dumps(dict(actual_exit=0,first_score_frame=1008,predicate_frame=1009,points_display=100,actions=post,manifest=pin(m))))
