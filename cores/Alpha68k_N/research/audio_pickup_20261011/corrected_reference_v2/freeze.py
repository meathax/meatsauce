"""Qualify observers and freeze one corrected finite reference result."""
from pathlib import Path
import csv,hashlib,json,struct
HERE=Path(__file__).resolve().parent
BASE=HERE.parent
RUN=HERE/'output'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
def rows(name):
 with (RUN/name).open(newline='') as f:return list(csv.DictReader(f))
def n(x,k):return int(x[k])
exit=json.loads((RUN/'exit.json').read_text());complete=json.loads((RUN/'complete.json').read_text())
states=rows('frame_states.csv');actors=rows('actors.csv');events=rows('events.csv');inputs=rows('inputs.csv');consumed=rows('consumed_inputs.csv');collision=rows('collision_reads.csv');producers=rows('producer_writes.csv');decisions=rows('decisions.csv')
ordinary=[x for x in actors if n(x,'base')!=0x20400 and n(x,'type') in (0x20,0x21,0x22,0x24,0x25)]
queued=[x for x in events if x['area']=='pickup_command_queue']
accepted=[x for x in events if x['area']=='sound_latch_write' and n(x,'mask')&0xff00 and (n(x,'data')>>8)&255==0x53]
sound=[x for x in events if x['area'] in ('sound_io','sound_memory')]
work=[x for x in events if x['area']=='work']
latch=[x for x in events if x['area']=='sound_latch_write']
clear=[x for x in producers if n(x,'address') in range(0x20420,0x20500,0x20) and n(x,'mask')&0xff00 and (n(x,'data')>>8)&255==0 and x['object_hex']!='outside_slots' and int(x['object_hex'][:2],16) in (0x20,0x21,0x22,0x24,0x25)]
score=[x for x in producers if n(x,'address') in (0x20300,0x20302,0x20370,0x20372)]
admission=json.loads((HERE/'admission.json').read_text())
checks={'MAME_actual_exit0':exit['actual_MAME_exit_code']==0,'supervisor_actual_exit0':json.loads((HERE/'worker_exit.json').read_text())['actual_exit_code']==0,'complete_no_frame_failure':exit['complete_present'] and not exit['failure_present'],'finite2400':len(states)==complete['fields'] and 1<=len(states)<=2400,'contiguous_fields':[n(x,'frame') for x in states]==list(range(len(states))),'eight_records_per_field':len(actors)==8*len(states),'decisions_one_per_field':len(decisions)==len(states),'legal_input_transitions_recorded':bool(inputs),'consumed_input_reads_nonvacuous':bool(consumed),'all_consumed_reads_correct_map':bool(consumed) and all(n(x,'address')==0xc0000 for x in consumed),'logger_work_writes_nonvacuous':bool(work),'logger_latch_writes_nonvacuous':bool(latch),'logger_sound_events_nonvacuous':bool(sound),'actual_coordinate_reads_nonvacuous':bool(collision),'source_pins_unchanged':all(sha(Path(x['path']))==x['sha256'] for x in admission['source_pins']),'prior_failed_manifest_immutable':sha(BASE/'import_manifest.json')=='5a348f2b60691b409fd8e8cd8937f1780c962f363da91c7bbffd11ef97c76a04'}
invariance=[]
for name in ('frame_states.csv','actors.csv','decisions.csv','inputs.csv','collision_reads.csv'):
 before=BASE/'reference_pilot_v1'/name;after=RUN/name
 invariance.append({'path':name,'before_sha256':sha(before),'after_sha256':sha(after),'exact_bytes':before.read_bytes()==after.read_bytes()})
for before in (BASE/'reference_pilot_v1').glob('frame_*'):
 after=RUN/before.name
 if after.exists():invariance.append({'path':before.name,'before_sha256':sha(before),'after_sha256':sha(after),'exact_bytes':before.read_bytes()==after.read_bytes()})
checks['observer_fix_preserves_all_retained_gameplay']=bool(invariance) and all(x['exact_bytes'] for x in invariance)
PNGs=[]
for png in RUN.glob('*.png'):
 b=png.read_bytes();assert b[:8]==b'\x89PNG\r\n\x1a\n'
 w,h,depth,colour=struct.unpack('>IIBB',b[16:26])
 PNGs.append({'path':str(png),'sha256':sha(png),'bytes':len(b),'width':w,'height':h,'bit_depth':depth,'colour_type':colour,'producer':'official MAME screen:snapshot; completed PNG, no screen:pixels'})
checks['completed_PNGs_nonvacuous']=bool(PNGs)
with (HERE/'applied_callback_tuples.csv').open('w',newline='') as f:
 writer=csv.writer(f);writer.writerow(['callback_frame','screen_frame','in0','in1','in2'])
 for x in states:writer.writerow([x[k] for k in ('frame','screen_frame','in0','in1','in2')])
absence=all(checks.values()) and not ordinary and not queued and not accepted
result={'scope':'One corrected finite authentic official MAME reference pilot; semantic pickup target remains unobserved','complete':complete,'actual_exit':exit,'checks':checks,'counts':{'fields':len(states),'actor_records':len(actors),'legal_input_transitions':len(inputs),'consumed_input_reads':len(consumed),'generic_events':len(events),'work_writes':len(work),'sound_latch_writes':len(latch),'sound_IO_DAC_events':len(sound),'coordinate_reads':len(collision),'producer_writes':len(producers),'ordinary_item_records':len(ordinary),'ordinary_clear_writes':len(clear),'score_writes':len(score),'queued53':len(queued),'accepted53':len(accepted),'completedPNGs':len(PNGs)},'ordinary_first_last':ordinary[:2]+ordinary[-2:] if ordinary else [],'queued53':queued,'accepted53':accepted,'clear_writes':clear,'score_writes':score[:16],'consumed_input_first_last':consumed[:2]+consumed[-2:] if consumed else [],'sound_first_last':sound[:2]+sound[-2:] if sound else [],'observer_gameplay_invariance':invariance,'completed_PNGs':PNGs,'qualified_finite_absence':absence,'absence_scope':'No ordinary type20/21/22/24/25 sampled in seven slots, queued53 or accepted53 in this exact 2400-field route. Not absence in game or proof of a gameplay bug.','semantic_pickup_qualified':False,'native_replay_qualified':False,'full_acceptance':False,'actual_analysis_exit_code':0 if all(checks.values()) else 1}
save(HERE/'result.json',result)
summary=f'''# Corrected pickup reference result

Official MAME exit {exit['actual_MAME_exit_code']}; supervisor exit recorded separately. {sum(checks.values())}/{len(checks)} observer/source checks pass. Finite route ended at {len(states)} fields; {len(ordinary)} ordinary-item records, {len(queued)} queued53 and {len(accepted)} accepted53. No pickup target was qualified and no native replay launched.

Observers now retain {len(consumed)} actual CPU input reads, {len(work)} work writes, {len(latch)} sound latch writes and {len(sound)} sound IO/DAC events. Coordinate reads: {len(collision)}. Completed PNGs: {len(PNGs)}. {sum(x['exact_bytes'] for x in invariance)}/{len(invariance)} retained gameplay/state/input/coordinate/PNG/RAM artifacts are byte-identical to the prior finite pilot. This qualifies the observer repair without changing guest behavior.

Qualified absence applies only to this legal finite route and seven object slots. The target (112,60) was a heuristic and did not reveal an ordinary pickup before the player stopped being active. Do not extend or repeat automatically. Further route discovery needs a source-backed opportunity or user interaction and root release. Callback tuples are preserved alongside consumed-read timestamps; they are not a fabricated native input adapter. No RAM, CPU, ROM, savestate or sound-command injection occurred.
'''
(HERE/'result.md').write_text(summary,encoding='utf-8',newline='\n')
small=[x for x in HERE.iterdir() if x.is_file() and x.suffix in ('.py','.json','.md','.csv','.log') and x.name!='import_manifest.json']
small += [x for x in RUN.iterdir() if x.is_file() and x.suffix in ('.json','.log')]
large=[x for x in RUN.iterdir() if x.is_file() and x not in small]
save(HERE/'import_manifest.json',{'schema':1,'scope':result['scope'],'small_import_files':[{'path':str(x),'sha256':sha(x),'bytes':x.stat().st_size} for x in small],'large_recovery_files':[{'path':str(x),'sha256':sha(x),'bytes':x.stat().st_size} for x in large],'admission_sha256':sha(HERE/'admission.json'),'actual_MAME_exit_code':exit['actual_MAME_exit_code'],'actual_analysis_exit_code':result['actual_analysis_exit_code'],'qualified_finite_absence':absence,'semantic_pickup_qualified':False,'native_replay_qualified':False})
print(json.dumps({'checks_passed':sum(checks.values()),'checks_total':len(checks),'counts':result['counts'],'gameplay_invariance':sum(x['exact_bytes'] for x in invariance),'invariance_total':len(invariance),'qualified_finite_absence':absence,'failed_checks':[x for x,v in checks.items() if not v],'manifest_sha256':sha(HERE/'import_manifest.json'),'actual_analysis_exit_code':result['actual_analysis_exit_code']}))
raise SystemExit(result['actual_analysis_exit_code'])
