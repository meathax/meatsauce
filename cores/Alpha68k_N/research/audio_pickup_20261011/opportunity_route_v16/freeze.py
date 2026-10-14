from pathlib import Path
import csv,hashlib,json,wave
D=Path(__file__).resolve().parent;R=D/'output'
assert not (D/'import_manifest.json').exists(),'Freeze already exists'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text())
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
assert (D/'worker_exit.json').exists(),'Worker not terminal'
a=load(D/'preparation.json');actual=load(R/'exit.json');worker=load(D/'worker_exit.json')
job=load(R/'job.json');assert job['argv']==load(D/'command.json')['argv']
for p in a['source_pins']:assert sha(Path(p['path']))==p['sha256'],p['path']
assert sha(D/'opportunity.lua')==a['lua_sha256']
complete=load(R/'complete.json') if (R/'complete.json').exists() else None
counts={};evidence={'tile_consumer2362':[],'tile_mutation2362':[],'effect_record_producers':[],'effect_record_clear':[],'queue53_source':[],'accepted53':[],'consumed53':[],'score_producers':[],'score_changes':[],'phase_transitions':[],'player_blocked_terrain':[]}
lastscore=None;phase=None;finalstate=None;finalroute=None
for path in sorted(R.glob('*.csv')):
 count=0
 with path.open(newline='') as f:
  for r in csv.DictReader(f):
   count+=1;n=path.name
   if n=='source_states.csv':
    finalstate=r;score=int(r['p1score'])
    if lastscore is not None and score!=lastscore:evidence['score_changes'].append(r)
    lastscore=score
   elif n=='route_steps.csv':
    finalroute=r
    if int(r['phase'])!=phase:evidence['phase_transitions'].append(r);phase=int(r['phase'])
   elif n=='work_ancestry.csv':
    ad=int(r['address']);data=int(r['data']);mask=int(r['mask']);pc=int(r['pc']);pre=int(r['preword'])
    if ad in (0x20c40,0x20c42) and 0x27be<=pc<=0x27f0:evidence['effect_record_producers'].append(r)
    if ad==0x20c40 and pre==0x101a and int(r['projected_word'])==0 and 0xb9f0<=pc<=0xba10:evidence['effect_record_clear'].append(r)
    if ad==0x2035e and data&mask&255==0x53 and 0xba00<=pc<=0xba12:evidence['queue53_source'].append(r)
    if 0x20300<=ad<=0x20302 and 0xb9d2<=pc<=0xbb54:evidence['score_producers'].append(r)
   elif n=='tile_consumer_reads.csv':
    if int(r['address'])==0x4101a and int(r['data'])==0x2362:evidence['tile_consumer2362'].append(r)
   elif n=='tile_producer_writes.csv':
    if int(r['address'])==0x4101a and int(r['preword'])==0x2362 and int(r['data'])!=0x2362:evidence['tile_mutation2362'].append(r)
   elif n=='consumed_commands.csv':
    if int(r['data'])&255==0x53:evidence['consumed53'].append(r)
   elif n=='events.csv':
    if r['area']=='sound_latch_write' and int(r['mask'])&0xff00 and int(r['data'])>>8&255==0x53:evidence['accepted53'].append(r)
   elif n=='movement_terrain_reads.csv':
    if int(r['a4'])==0x20400 and int(r['data'])&0x2fff<0xfb0 and 0x515a<=int(r['pc'])<=0x5204:
     if len(evidence['player_blocked_terrain'])<64:evidence['player_blocked_terrain'].append(r)
 counts[path.name]=count
wav=None
if (R/'production.wav').exists():
 with wave.open(str(R/'production.wav'),'rb') as w:wav={'rate':w.getframerate(),'channels':w.getnchannels(),'sample_width':w.getsampwidth(),'frames':w.getnframes(),'sha256':sha(R/'production.wav')}
semantic=all(evidence[k] for k in ['tile_consumer2362','tile_mutation2362','effect_record_producers','effect_record_clear','queue53_source','accepted53','consumed53','score_changes'])
observer_pass=actual['actual_MAME_exit_code']==0 and worker['actual_exit_code']==0 and complete is not None and not (R/'failure.txt').exists() and counts.get('consumed_inputs.csv',0)>0 and counts.get('movement_terrain_reads.csv',0)>0 and counts.get('work_ancestry.csv',0)>0 and wav and wav['rate']==48000
result={'actual_MAME_exit_code':actual['actual_MAME_exit_code'],'actual_supervisor_exit_code':worker['actual_exit_code'],'complete':complete,'observer_qualified':bool(observer_pass),'semantic_pickup_pass':bool(observer_pass and semantic),'native_acceptance':False,'counts':counts,'final_source_state':finalstate,'final_route_state':finalroute,'wave':wav,'evidence':evidence,'limits':['Official MAME reference only; no native replay','Static geometry forecast alone never qualifies pickup','PC is MAME executed observer PC, often next instruction; retained exact ROM pins','Player blocked terrain evidence is capped64 rows; complete raw CSV retained']}
save(D/'result.json',result)
files=[]
for p in sorted(D.rglob('*')):
 if p.is_file():files.append({'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)})
save(D/'import_manifest.json',{'scope':'one bounded genuine official MAME reference route','result_sha256':sha(D/'result.json'),'source_pins':a['source_pins'],'files':files,'actual_MAME_exit_code':actual['actual_MAME_exit_code'],'observer_qualified':bool(observer_pass),'semantic_pickup_pass':bool(observer_pass and semantic),'native_acceptance':False})
print(json.dumps({'manifest':str(D/'import_manifest.json'),'sha256':sha(D/'import_manifest.json'),'fields':complete and complete['fields'],'reason':complete and complete['reason'],'actual_MAME_exit_code':actual['actual_MAME_exit_code'],'actual_supervisor_exit_code':worker['actual_exit_code'],'observer_qualified':bool(observer_pass),'semantic_pickup_pass':bool(observer_pass and semantic),'final':finalroute,'phases':[(r['frame'],r['phase'],r['name']) for r in evidence['phase_transitions']],'evidence_counts':{k:len(v) for k,v in evidence.items()}}))
