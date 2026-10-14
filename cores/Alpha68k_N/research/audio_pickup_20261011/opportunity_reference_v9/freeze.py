from pathlib import Path
import csv,hashlib,json,struct,wave,collections
D=Path(__file__).resolve().parent;R=D/'output'
assert not (D/'import_manifest.json').exists()
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def rows(n):
 with (R/n).open(newline='') as f:return list(csv.DictReader(f))
def number(x,k):return int(x[k])
exit=json.loads((R/'exit.json').read_text());complete=json.loads((R/'complete.json').read_text());ad=json.loads((D/'admission.json').read_text());worker=json.loads((D/'worker_exit.json').read_text())
st=rows('source_states.csv');states=rows('frame_states.csv');actors=rows('actors.csv');inputs=rows('inputs.csv');consumed=rows('consumed_inputs.csv');decisions=rows('decisions.csv');reads=rows('tile_consumer_reads.csv');tw=rows('tile_producer_writes.csv')
counts=collections.Counter();queued=[];accepted=[];selector=[];clears=[];tile_candidates=[];tile2362=[];awards=[]
with (R/'events.csv').open(newline='') as f:
 for x in csv.DictReader(f):
  counts[x['area']]+=1
  if x['area']=='pickup_command_queue':queued.append(x)
  if x['area']=='sound_latch_write' and number(x,'mask')&0xff00 and (number(x,'data')>>8)&255==0x53:accepted.append(x)
with (R/'work_ancestry.csv').open(newline='') as f:
 for x in csv.DictReader(f):
  counts['work_ancestry']+=1;a=number(x,'address');pc=number(x,'pc')
  if 0x20024<=a<=0x2002b:selector.append(x)
  if 0x20300<=a<=0x20303 or 0x20370<=a<=0x20373:awards.append(x)
  if 0x20c40<=a<=0x20c5b and 0xb9d2<=pc<=0xba14:clears.append(x)
for x in tw:
 if 0x2340<=number(x,'data')<0x2370:tile_candidates.append(x)
 if number(x,'address')==0x4101a and number(x,'data')==0x2362:tile2362.append(x)
game_selectors=[x for x in selector if number(x,'frame')>=720 and number(x,'preword')!=number(x,'projected_word')]
sel_instructions=collections.Counter(number(x,'pc') for x in game_selectors)
pngs=[]
for p in sorted(R.glob('*.png')):
 b=p.read_bytes();assert b[:8]==b'\x89PNG\r\n\x1a\n';w,h=struct.unpack('>II',b[16:24]);pngs.append({'path':str(p),'sha256':sha(p),'width':w,'height':h,'bytes':len(b)})
wav={}
with wave.open(str(R/'production.wav'),'rb') as w:wav={'sample_rate':w.getframerate(),'channels':w.getnchannels(),'sample_bytes':w.getsampwidth(),'frames':w.getnframes(),'sha256':sha(R/'production.wav')}
fg_rows=sum(1 for _ in (R/'foreground_frames.csv').open())-1
checks={'actual_MAME_exit0':exit['actual_MAME_exit_code']==0,'worker_exit0':worker['actual_exit_code']==0,'complete_no_Lua_failure':exit['complete_present'] and not exit['failure_present'],'finite_fields':0<len(st)==len(states)==complete['fields']<=1800,'contiguous_fields':[number(x,'frame') for x in st]==list(range(len(st))),'actors_eight_per_field':len(actors)==len(st)*8,'foreground_every_field':fg_rows==len(st),'decisions_every_field':len(decisions)==len(st),'legal_transitions_nonvacuous':bool(inputs) and all(number(x,'mask') in (1,2,4,8,16,32,128) for x in inputs),'actual_input_consumed':bool(consumed) and all(number(x,'address')==0xc0000 for x in consumed),'allwork_logger_nonvacuous':counts['work_ancestry']>0 and bool(selector),'actual_tile_consumers_nonvacuous':bool(reads),'actual_tile_writes_nonvacuous':bool(tw),'sound_events_nonvacuous':counts['sound_io']+counts['sound_memory']>0,'raw_MAME_WAV48000_nonempty':wav['sample_rate']==48000 and wav['frames']>0,'completed_PNGs':bool(pngs),'sourcepins_CAS_unchanged':all(sha(Path(x['path']))==x['sha256'] for x in ad['source_pins']) and sha(D/'opportunity.lua')==ad['lua_sha256']}
with (D/'actual_applied_callback_tuples.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['callback_frame','screen_frame','in0','in1','in2']);w.writerows([[x[k] for k in ['frame','screen_frame','in0','in1','in2']] for x in states])
absence=all(checks.values()) and not queued and not accepted
opportunity=[x for x in st if number(x,'tile_candidates')>0]
aligned=[x for x in decisions if x['reason']!='align_actual_5292_xNibble10' and number(x,'frame')>=720]
semantic=False
result={'scope':'ONE genuine officialMAME legal source opportunity probe, no native run','actual_exit':exit,'worker_exit':worker,'complete':complete,'checks':checks,'counts':dict(counts),'source_states':len(st),'consumed_reads':len(consumed),'actual_input_transitions':len(inputs),'actual_tile_reads':len(reads),'actual_tile_writes':len(tw),'ordinary_type_records':sum(number(x,'type') in [32,33,34,36,37] for x in actors if number(x,'base')!=0x20400),'selector_score_writes':len(selector),'gameplay_changed_score_writes':len(game_selectors),'gameplay_selector_PC_counts':dict(sel_instructions),'gameplay_selector_first_last':game_selectors[:6]+game_selectors[-6:],'source_award_first_last':awards[:4]+awards[-4:],'pickup_tile_producer_count':len(tile_candidates),'first_tile2362_4101a':tile2362[:3],'actual_pickup_opportunity_fields':len(opportunity),'opportunity_first_last':opportunity[:2]+opportunity[-2:],'source_states_first_last':st[:2]+st[-3:],'decision_tail':decisions[-8:],'first_aligned':aligned[:1],'queued53':queued,'accepted53':accepted,'tile_effect_clear_ancestry':clears,'MAME_WAV':wav,'PNGs':pngs,'qualified_finite_absence':absence,'semantic_pickup_qualified':semantic,'native_replay_qualified':False,'absence_limit':'No source-qualified queued/accepted53 in this bounded legal route. Actual loaded tiles, selectors and mapping reported separately; no game-wide absence claim. No automatic repeat or extension.','actual_analysis_exit_code':0 if all(checks.values()) else 1}
save(D/'result.json',result)
(D/'result.md').write_text(f"Official MAME and supervisor exit0; {sum(checks.values())}/{len(checks)} observation checks. Stopped at {len(st)} fields: {complete['reason']}. Queued53={len(queued)}, accepted53={len(accepted)}; semantic pickup remains unqualified. Actual pickup tile producers={len(tile_candidates)}, foreground opportunity fields={len(opportunity)}, gameplay changed score writes={len(game_selectors)}. No native replay or repeat. Result.json retains exact field/producer evidence and coverage limits.\n")
files=[p for p in D.rglob('*') if p.is_file() and p.name!='import_manifest.json']
save(D/'import_manifest.json',{'scope':result['scope'],'files':[{'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size} for p in files],'actual_MAME_exit_code':exit['actual_MAME_exit_code'],'actual_worker_exit_code':worker['actual_exit_code'],'actual_analysis_exit_code':result['actual_analysis_exit_code'],'qualified_finite_absence':absence,'semantic_pickup_qualified':False,'native_replay_qualified':False})
print(json.dumps({'fields':len(st),'reason':complete['reason'],'checks':sum(checks.values()),'total':len(checks),'failed':[k for k,v in checks.items() if not v],'tile_producers':len(tile_candidates),'opportunity_fields':len(opportunity),'changed_score_writes':len(game_selectors),'selector_PC_counts':dict(sel_instructions),'queued53':len(queued),'accepted53':len(accepted),'manifest_sha256':sha(D/'import_manifest.json'),'actual_analysis_exit_code':result['actual_analysis_exit_code']}))
raise SystemExit(result['actual_analysis_exit_code'])
