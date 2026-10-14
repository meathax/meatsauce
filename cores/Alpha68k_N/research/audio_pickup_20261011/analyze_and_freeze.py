"""Freeze the actual finite official-MAME pilot without acceptance inference."""
from pathlib import Path
import csv,hashlib,json
HERE=Path(__file__).resolve().parent
RUN=HERE/'reference_pilot_v1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
def rows(name):
 with (RUN/name).open(newline='') as f:return list(csv.DictReader(f))
def n(row,k):return int(row[k])
exit=json.loads((RUN/'exit.json').read_text());complete=json.loads((RUN/'complete.json').read_text())
states=rows('frame_states.csv');events=rows('events.csv');actors=rows('actors.csv');decisions=rows('decisions.csv');consumed=rows('consumed_inputs.csv');collision=rows('collision_reads.csv');producers=rows('producer_writes.csv');inputs=rows('inputs.csv')
ordinary=[x for x in actors if n(x,'base')!=0x20400 and n(x,'type') in (0x20,0x21,0x22,0x24,0x25)]
queued=[x for x in events if x['area']=='pickup_command_queue']
latches=[x for x in events if x['area']=='sound_latch_write' and n(x,'mask')&0xff00 and (n(x,'data')>>8)&255==0x53]
clear=[x for x in producers if n(x,'address') in range(0x20420,0x20500,0x20) and n(x,'mask')&0xff00 and (n(x,'data')>>8)&255==0 and x['object_hex']!='outside_slots' and int(x['object_hex'][:2],16) in (0x20,0x21,0x22,0x24,0x25)]
scores=[x for x in producers if n(x,'address') in (0x20300,0x20302,0x20370,0x20372)]
sound=[x for x in events if x['area'] in ('sound_io','sound_memory')]
first_move=next((x for x in decisions if n(x,'desired')&15),None)
checks={'actual_MAME_exit_zero':exit['actual_native_exit_code']==0,'Lua_complete_without_failure':exit['complete_present'] and not exit['failure_present'],'finite_fields':len(states)==complete['fields'] and 1<=len(states)<=2400,'all_field_labels_contiguous':[n(x,'frame') for x in states]==list(range(len(states))),'eight_records_per_field':len(actors)==8*len(states),'applied_tuple_per_field':len(decisions)==len(states),'legal_inputs_recorded':bool(inputs),'actual_CPU_input_reads_nonvacuous':bool(consumed),'source_pins_still_match':True}
admission=json.loads((HERE/'admission_manifest.json').read_text())
for x in admission['files']+admission['source_pins']:
 p=Path(x['path']);p=p if p.is_absolute() else HERE/p
 checks['source_pins_still_match'] &= sha(p)==x['sha256']
# These callback frame tuples are a reproducible recording, not a native replay adapter.
with (HERE/'applied_callback_tuples.csv').open('w',newline='') as f:
 writer=csv.writer(f);writer.writerow(['callback_frame','screen_frame','in0','in1','in2'])
 for x in states:writer.writerow([x[k] for k in ('frame','screen_frame','in0','in1','in2')])
result={'scope':'One finite authentic official MAME reference pilot; semantic/native qualification remains separate','actual_exit':exit,'complete':complete,'checks':checks,'counts':{'states':len(states),'actors':len(actors),'events':len(events),'inputs':len(inputs),'consumed_CPU_input_reads':len(consumed),'collision_reads':len(collision),'producer_writes':len(producers),'ordinary_item_records':len(ordinary),'ordinary_clear_writes':len(clear),'score_writes':len(scores),'queued53':len(queued),'accepted_latch53':len(latches),'sound_IO_DAC_events':len(sound),'completed_PNGs':len(list(RUN.glob('*.png')))},'first_movement':first_move,'ordinary_item_first_last':ordinary[:2]+ordinary[-2:] if ordinary else [],'clear_writes':clear,'score_writes':scores[:16],'queued53':queued,'accepted_latch53':latches,'collision_first_last':collision[:2]+collision[-2:] if collision else [],'last_decisions':decisions[-4:],'semantic_pickup_qualified':False,'native_replay_qualified':False,'full_acceptance':False,'actual_analysis_exit_code':0 if all(checks.values()) else 1}
save(HERE/'pilot_result.json',result)
small=[x for x in HERE.iterdir() if x.is_file() and x.suffix in ('.py','.json','.md','.log','.csv') and x.name!='import_manifest.json']
small += [x for x in RUN.iterdir() if x.is_file() and x.suffix in ('.json','.log')]
large=[x for x in RUN.iterdir() if x.is_file() and x not in small]
save(HERE/'import_manifest.json',{'schema':1,'scope':result['scope'],'small_import_files':[{'path':str(x),'bytes':x.stat().st_size,'sha256':sha(x)} for x in small],'large_recovery_files':[{'path':str(x),'bytes':x.stat().st_size,'sha256':sha(x)} for x in large],'admission_sha256':sha(HERE/'admission_manifest.json'),'actual_exit_code':result['actual_analysis_exit_code'],'semantic_pickup_qualified':False,'native_replay_qualified':False})
print(json.dumps({'complete':complete,'counts':result['counts'],'first_movement':first_move,'last_decision':decisions[-1] if decisions else None,'checks_passed':sum(checks.values()),'checks_total':len(checks),'manifest_sha256':sha(HERE/'import_manifest.json'),'actual_analysis_exit_code':result['actual_analysis_exit_code']}))
raise SystemExit(result['actual_analysis_exit_code'])
