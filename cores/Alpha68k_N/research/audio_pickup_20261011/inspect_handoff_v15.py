from pathlib import Path
import csv,hashlib,json
P=Path(__file__).resolve().parent;V=P/'opportunity_route_v14';R=V/'output';D=P/'route_handoff_v15';D.mkdir()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(V/'import_manifest.json')=='bec9a470dc803fd1db9c3a2cc4a965458b518d7f1739f9bec8c5c5d8aacf9aa1'
out={};addresses=set()
for name in ['actors.csv','source_states.csv','frame_states.csv','route_steps.csv','inputs.csv','consumed_inputs.csv','movement_terrain_reads.csv']:
 rows=[]
 with (R/name).open(newline='') as f:
  for r in csv.DictReader(f):
   if 1152<=int(r['frame'])<=1156 and (name!='actors.csv' or int(r['base'])==0x20400):
    rows.append(r)
    if name=='actors.csv':addresses.add(0x20000+int(r['coord_offset']))
 out[name]=rows
rows=[]
with (R/'work_ancestry.csv').open(newline='') as f:
 for r in csv.DictReader(f):
  if 1152<=int(r['frame'])<=1156 and int(r['a4'])==0x20400 and (int(r['address']) in addresses|{0x20402,0x20346,0x20344,0x20340,0x20342,0x20112}):rows.append(r)
out['player_work_ancestry']=rows
result={'source_pins':json.loads((V/'preparation.json').read_text())['source_pins'],'actual_reference_manifest':str(V/'import_manifest.json'),'reference_sha256':sha(V/'import_manifest.json'),'observations':out,'scope':'source-only actual turn-handoff diagnosis; no new runtime','hypothesis':'A field callback changes legal controller after a movement update has already selected Left; the next movement can use that pending direction. Exact read/write rows are retained, not assumed from guard name.','route_limit':'X110 remains in first opening80..111; strict exactX111 guard stopped before another Up update. This does not prove complete route or dynamic obstacle absence.','next_controller_proposal':'Wait for observed direction/movement handoff before asserting exact vertical X. Accept safe opening interval at Up turns, then adjust actual lateral distance to the next source endpoint; all map/HP/deactivation/stall/finite guards retained. No runtime authorization inferred.'}
(D/'findings.json').write_text(json.dumps(result,indent=2)+'\n')
files=[{'path':str(D/'findings.json'),'bytes':(D/'findings.json').stat().st_size,'sha256':sha(D/'findings.json')},{'path':str(Path(__file__)),'sha256':sha(Path(__file__))}]
(D/'import_manifest.json').write_text(json.dumps({'scope':result['scope'],'files':files,'reference_sha256':result['reference_sha256'],'native_acceptance':False},indent=2)+'\n')
print(json.dumps({'manifest':str(D/'import_manifest.json'),'sha256':sha(D/'import_manifest.json'),'actor_coordinate_word_addresses':[hex(x) for x in addresses],'port_reads':[(r['frame'],hex(int(r['data'])),hex(int(r['pc']))) for r in out['consumed_inputs.csv']],'input_transitions':out['inputs.csv'],'player_direction_writes':[(r['frame'],hex(int(r['data'])),hex(int(r['mask'])),hex(int(r['pc'])),hex(int(r['projected_word']))) for r in rows if int(r['address'])==0x20402],'player_coord_writes':[(r['frame'],hex(int(r['data'])),hex(int(r['pc']))) for r in rows if int(r['address']) in addresses]}))
