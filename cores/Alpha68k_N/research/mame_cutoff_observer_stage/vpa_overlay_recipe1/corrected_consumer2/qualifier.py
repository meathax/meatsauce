"""Only qualifies already completed single overlay replay; never starts guest."""
import csv,hashlib,json,wave
from pathlib import Path
HERE=Path(__file__).resolve().parents[2];RECIPE=HERE/'vpa_overlay_recipe1'
def pin(p):
 b=p.read_bytes();return {'path':str(p),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def rows(p):
 with p.open(newline='') as f:return list(csv.DictReader(f))
def pcm(p):
 with wave.open(str(p),'rb') as w:return (w.getnchannels(),w.getsampwidth(),w.getframerate(),w.getnframes(),w.readframes(w.getnframes()))
def logrecords(p,prefix):return [l[l.index(prefix):].strip() for l in p.read_text(errors='replace').splitlines() if prefix in l]
a=json.loads((RECIPE/'admission.json').read_text());reference=Path(a['reference']);capture=Path(a['capture'])
checks={'actual_build0':json.loads((RECIPE/'build_exit.json').read_text())['exit_code']==0,'actual_MAME0':json.loads((RECIPE/'mame_exit.json').read_text())['exit_code']==0}
csv_checks={p.name:(capture/p.name).exists() and rows(p)==rows(capture/p.name) for p in reference.glob('*.csv')}
array_checks={p.name:(capture/p.name).exists() and p.read_bytes()==(capture/p.name).read_bytes() for p in reference.glob('frame_*') if p.suffix in {'.rgb','.bin'}}
checks.update(original12CSVsexact=len(csv_checks)==12 and all(csv_checks.values()),originalwholearrays_exact=bool(array_checks) and all(array_checks.values()),audioPCM_exact=pcm(reference/'audio.wav')==pcm(capture/'audio.wav'))
checks['original_recorder_exact']=(capture/'loaded_recorder.lua').read_bytes()==(reference/'loaded_recorder.lua').read_bytes()
cutoff=logrecords(reference/'error.log','IRQ_CUTOFF,');newcutoff=logrecords(capture/'error.log','IRQ_CUTOFF,')
checks['all_original_cutoff_records_exact']=len(cutoff)==130 and cutoff==newcutoff
newlog=(capture/'error.log').read_text(errors='replace')+'\n'+(RECIPE/'mame_run.log').read_text(errors='replace')
checks['no_LUA_error']=not any(s in newlog.lower() for s in ['lua error','error running','stack traceback'])
fields=['request_cycle','previous_last_vpa_cycle','return_cycle','request_cycle_mod10','total_cycles','icount','CPU_local_ticks48MHz','machine_ticks48MHz','pc','ipc','ir','ird','irc','sr','level','pending','next']
raw=logrecords(capture/'error.log','IRQ_VPA,');records=[];malformed=[]
for line in raw:
 parts=line.split(',')
 if len(parts)!=18:malformed.append(line);continue
 try:records.append(dict(zip(fields,map(int,parts[1:]))))
 except ValueError:malformed.append(line)
checks['17fields_wellformed']=bool(records) and not malformed
checks['bounded_request_window']=bool(records) and all(5500000<=r['request_cycle']<=6200000 for r in records)
checks['original_return_algorithm_exact']=bool(records) and all(r['request_cycle_mod10']==r['request_cycle']%10 and r['return_cycle']==(r['previous_last_vpa_cycle'] if r['previous_last_vpa_cycle']>=r['request_cycle'] else r['request_cycle']-r['request_cycle']%10+(10 if r['request_cycle']%10<7 else 20)) for r in records)
groups=[]
for r in records:
 key=(r['return_cycle'],r['level'])
 if not groups or groups[-1]['key']!=key:groups.append({'key':key,'records':[]})
 groups[-1]['records'].append(r)
iacks=rows(capture/'cpu_space_iack.csv');rowmap=[]
checks['ten_returngroups_ordered_active_SR_next_IACK_levels']=len(groups)==len(iacks)==10 and all(all(((r['sr']>>8)&7)==((r['next']>>24)&7)==(int(i['address'])&15)//2 for r in g['records']) for g,i in zip(groups,iacks))
if checks['ten_returngroups_ordered_active_SR_next_IACK_levels']:
 for index,(g,i) in enumerate(zip(groups,iacks)):
  rowmap.append({'IACK_index':index,'frame':int(i['frame']),'address':int(i['address']),'actual_MAME_callback_master_ticks':int(i['master_ticks']),'actual_MAME_callback_CPU_ticks':int(i['cpu_ticks']),'VPA_records':g['records'],'returncycle_minus_callbackCPUticks':g['key'][0]-int(i['cpu_ticks']),'unit_epoch_note':'CPUcycle difference is labeled; CPUlocal and scheduler machine48MHz timestamps remain separate; no assumedCPU*8 epoch or nativeEphase.'})
pin_mismatches=[{'expected':p,'actual':pin(Path(p['path']))} for p in a['protected_pins']+a['required_pins'] if pin(Path(p['path']))!=p]
checks['all_protected_and_required_pins_unchanged']=all(pin(Path(p['path']))==p for p in a['protected_pins']+a['required_pins'])
result={'checks':checks,'PASS':all(checks.values()),'csv_comparisons':csv_checks,'wholearrays':array_checks,'raw_VPA_records':records,'postrun_pin_mismatches':pin_mismatches,'current_input_level_note':'Rawlevel=m_int_level describes currentIPL input; activeacklevel comes from alreadycommittedSR_I and m_next_state bits24..26. Raw17fields remainunaltered.','malformed':malformed,'actual_rowmap':rowmap,'cutoff_count':len(newcutoff),'rawlogs':[pin(capture/'error.log'),pin(RECIPE/'mame_run.log')],'B16_closed':False,'physical_fault_proven':False,'three_plus8_proven':False,'no_CPU_clock_IRQ_patch':True,'limits':a['limits']}
(RECIPE/'corrected_consumer2/qualification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'checks':checks,'PASS':result['PASS'],'VPArows':len(records),'returngroups':len(groups),'rowmaps':len(rowmap),'qualification':pin(RECIPE/'corrected_consumer2/qualification.json')}))
raise SystemExit(0 if result['PASS'] else 1)
