"""Interpret only accepted finite records; preserve bus and callback boundaries."""
from pathlib import Path
import csv,json,hashlib,shutil
HERE=Path(__file__).resolve().parent
OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def rows(p):return [{k:int(v) for k,v in x.items()} for x in csv.DictReader(p.open())]
def save(n,x):(HERE/n).write_text(json.dumps(x,indent=2)+'\n')
q=json.loads((HERE/'qualification.json').read_text());assert q['accepted']
a=json.loads((HERE/'admission.json').read_text())
assert all(sha(OLD/p)==h for p,h in a['source_pins'].items())
native=OLD/'sim/captures/rtl/irq_ordinary_cutoff61'
mame=OLD/'sim/captures/kyros/mame_ordinary_cutoff61'
raw=rows(native/'ordinary_bus.csv');rom=rows(mame/'ordinary_rom.csv')
events=list(csv.DictReader((mame/'events.csv').open()))
cycles=[];active=[];starts=False
for x in raw:
 if x['asn_before']==1 and x['asn_after']==0:active=[];starts=True
 if x['asn_after']==0 or x['asn_before']==0:active.append(x)
 if x['asn_before']==0 and x['asn_after']==1 and active:
  lane=next((z for z in active if z['attrs_after']&3!=3),None)
  accept=next((z for z in active if z['transactions_after']!=z['transactions_before']),None)
  latched=next((z for z in active if z['rdtack_before']==1 and z['rdtack_after']==0),None)
  cap=[z for z in active if z['clks_before']&1 and z['to_irc_before']]
  db=[z for z in active if z['clks_before']&1 and z['to_dbin_before']]
  if lane and accept and starts:
   c={'as_assert_tick':active[0]['tick'],'ds_assert_tick':lane['tick'],'as_release_tick':x['tick'],'address':lane['address_after'],'attrs':lane['attrs_after'],'write_data':lane['dout_after'],'accepted_tick':accept['tick'],'external_DTACKn_after_accept':accept['dtack_n_after'],'registered_DTACKn_tick':latched['tick'] if latched else None,'irc_capture_ticks':[z['tick'] for z in cap],'dbin_capture_ticks':[z['tick'] for z in db],'all_irc_captures_equal_preedge_DI':all(z['irc_after']==z['din_before'] for z in cap),'accepted_data':accept['din_after'],'microaddr_at_accept':accept['microaddr_after'],'nanoaddr_at_accept':accept['nanoaddr_after']}
   c['accept_minus_DS']=c['accepted_tick']-c['ds_assert_tick']
   c['registered_DTACKn_minus_DS']=c['registered_DTACKn_tick']-c['ds_assert_tick'] if latched else None
   c['final_IRC_minus_DS']=cap[-1]['tick']-c['ds_assert_tick'] if cap else None
   cycles.append(c)
  active=[];starts=False
cases=[]
for level,targets in [(1,[0x411b0,0x411b2]),(2,[0x41502,0x41504])]:
 iterations=[]
 for dest in targets:
  store=next(c for c in cycles if c['address']==dest and c['attrs']==0 and c['write_data']==32)
  me=next(r for r in events if int(r['address'])==dest and int(r['data'])==32 and r['area']=='tiles2')
  mt=int(me['master_ticks']);dt=store['ds_assert_tick']
  fetches=[]
  for addr in [0x854,0x856,0x858,0x85a]:
   n=[c for c in cycles if c['address']==addr and c['attrs']==4 and (dt-140<=c['ds_assert_tick']<=dt if addr!=0x85a else dt<c['ds_assert_tick']<dt+80)]
   m=[r for r in rom if r['address']==addr and (mt-140<=r['machine_ticks']<=mt if addr!=0x85a else mt<r['machine_ticks']<mt+80)]
   assert len(n)==len(m)==1,(level,dest,addr,len(n),len(m))
   assert n[0]['accepted_data']==m[0]['data']
   fetches.append({'address':addr,'data':m[0]['data'],'native':n[0],'MAME_callback':m[0],'MAME_callback_minus_native_DS':m[0]['machine_ticks']-n[0]['ds_assert_tick'],'MAME_callback_minus_native_AS':m[0]['machine_ticks']-n[0]['as_assert_tick']})
  nn=next(c for c in cycles if c['address']==0x854 and dt<c['ds_assert_tick']<dt+120)
  nm=next(r for r in rom if r['address']==0x854 and mt<r['machine_ticks']<mt+120)
  native_phase=[fetches[2]['native']['ds_assert_tick'],dt,fetches[3]['native']['ds_assert_tick'],nn['ds_assert_tick']]
  mame_phase=[fetches[2]['MAME_callback']['machine_ticks'],mt,fetches[3]['MAME_callback']['machine_ticks'],nm['machine_ticks']]
  intervals=lambda x:[y-x for x,y in zip(x,x[1:])]
  iterations.append({'destination':dest,'value':32,'native_store':store,'MAME_store_callback_tick':mt,'MAME_callback_minus_native_DS':mt-dt,'matched_ROM_fetches':fetches,'native_subphase_ticks_858_store_85a_next854':intervals(native_phase),'MAME_callback_subphase_ticks_858_store_85a_next854':intervals(mame_phase),'native_prefetch_856_to_85a':fetches[3]['native']['ds_assert_tick']-fetches[1]['native']['ds_assert_tick'],'MAME_prefetch_856_to_85a':fetches[3]['MAME_callback']['machine_ticks']-fetches[1]['MAME_callback']['machine_ticks'],'native_prefetch_85a_to_next856':nn['ds_assert_tick']+32-fetches[3]['native']['ds_assert_tick'],'MAME_prefetch_85a_to_next856':nm['machine_ticks']+32-fetches[3]['MAME_callback']['machine_ticks']})
 cases.append({'level':level,'iterations':iterations,'native_store_DS_period':iterations[1]['native_store']['ds_assert_tick']-iterations[0]['native_store']['ds_assert_tick'],'MAME_callback_store_period':iterations[1]['MAME_store_callback_tick']-iterations[0]['MAME_store_callback_tick']})
ordinary=[c for c in cycles if (c['address'] in [0x854,0x856,0x858,0x85a] and c['attrs']==4) or c['address'] in [0x411b0,0x411b2,0x41502,0x41504]]
checks={'admitted_sources_unchanged_after_pair':True,'qualified_pair_checks_preserved':all(q['checks'].values()),'four_destinations_and_data_exact':len(cases)==2 and all(len(c['iterations'])==2 for c in cases),'all_two_loop_periods176':all(c['native_store_DS_period']==c['MAME_callback_store_period']==176 for c in cases),'all_accepts_DS_plus1':all(c['accept_minus_DS']==1 for c in ordinary),'all_registered_DTACKn_DS_plus4':all(c['registered_DTACKn_minus_DS']==4 for c in ordinary),'all_external_DTACKn_low_on_accept':all(c['external_DTACKn_after_accept']==0 for c in ordinary),'all_qualified_IRC_preedge_DI_exact':all(c['all_irc_captures_equal_preedge_DI'] for c in ordinary),'all_ordinary_read_final_IRC_DS_plus20':all(c['final_IRC_minus_DS']==20 for c in ordinary if c['attrs']==4),'all_subphase_vectors_equal_in_each_implementation':all(i['native_subphase_ticks_858_store_85a_next854']==[40,24,48] and i['MAME_callback_subphase_ticks_858_store_85a_next854']==[32,32,48] for c in cases for i in c['iterations']),'all_bus_callback_minus_AS_constant66':all(f['MAME_callback_minus_native_AS']==-66 for c in cases for i in c['iterations'] for f in i['matched_ROM_fetches']) and all(i['MAME_store_callback_tick']-i['native_store']['as_assert_tick']==-66 for c in cases for i in c['iterations'])}
source=Path(r'D:\Arcade\AI\mame289\src\devices\cpu\m68000\m68000-sdf.cpp')
lines=source.read_text().splitlines()
source_evidence={'MAME_source':str(source),'sha256':sha(source),'MOVE':{'lines':[60354,60364,60382,60384,60404],'contract':'Three real memory accesses charged4 CPUcycles each: following-opcode fetch, destination store, following displacement fetch; 12 cycles at6MHz =96 masterticks. IR→IRD interrupt selection lies after write before final fetch.'},'DBRA_taken':{'lines':[103069,103077,103103,103111],'contract':'Taken DBRA path has two real prefetch accesses charged4 CPUcycles each plus2 internal cycles:10cycles =80 masterticks; execution-generated microcode already token-qualified against private PE.'},'fx68k':{'path':str(OLD/'rtl/vendor/fx68k/fx68k.sv'),'sha256':sha(OLD/'rtl/vendor/fx68k/fx68k.sv'),'lines':[220,1759,1761,2337,2340,2341],'contract':'rDtack is latched DTACKn, active low. IRC/DBIN capture on xToIRC/xToDBIN AND enPhi2; repeated samples continue through wait states. busEnd=~rDtack|iStop; completion on S6. Final capture and AS/DS/board acceptance are separate boundaries.'}}
report={'checks':checks,'accepted':all(checks.values()),'cases':cases,'complete_captured_bus_cycles':cycles,'ordinary_cycle_count':len(ordinary),'source_evidence':source_evidence,'qualified_clock':{'master_hz':48000000,'cpu_hz':6000000,'ticks_per_CPUcycle':8,'inputs_ROM_scheduler_clocks_changed':False},'cause':'The finite ordinary loops have constant176tick period and fixed native board/DTACK/finalcapture latency. Native DS subphases40/24/48 vs MAME callback32/32/48 differ+8/-8/0 and cancel. More decisively, every matched ROM callback and destination store callback is66ticks before its native AS assertion. The additional8tick store DS delta is the real68000 write AS-to-strobe delay, not a drift or a placement fault. Deterministic ordinary bus-wait inflation is excluded within these captured loops. The existing74tick upcoming-MOVE IRQ phase separation predates these iterations; initial phase and callback-vs-CPU capture semantics remain to be localized.', 'cycle_accounting_limit':'Native and MAME prefetch windows856→85a96ticks and85a→next85680ticks match. MAME MOVE12/DBRA10cycles are source-charged handler cycles; prefetch windows are not architectural retirement. Do not equate callback, AS/DS, acceptance, final capture or IR→IRD. Constant66offset is a measured comparison, not permission to shift clocks or traces.', 'smallest_supported_fix':'No RTL/clock/wait/IRQ gate or bus-placement patch is justified. Native bus shape matches source4cycleaccesses, writeAS-to-DS8ticks,22cycle loop; board already accepts DS+1 and meets nextPhi2DTACK. Required next evidence: earliest common instruction/prefetch/IR→IRD landmark in existing boot traces to find origin of constant phase, and a qualified68000 bus/IRQ sampling timing contract before selecting a physical correction. Preserve source-defined MAME callback and donor final-latch boundaries.', 'method_correction':'Provisional report failed its subphase check because the investigator associated a85a fetch with the next loop when reading partial console output. Original failed script/report preserved under failed_provisional; accepted report uses exact destination/data/order and independent four-ROM-fetch join in all4cases.', 'physical_cause_proven':False,'B16_closed':False,'MAME_bug_proven':False,'new_replay_count':1}
save('timing_cause_report.json',report)
assert all(checks.values()),checks
for name in ['job','build_exit','exit']:
 shutil.copy2(OLD/('research/irq_ordinary_cutoff61_'+name+'.json'),HERE/('native_'+name+'.json'))
freeze_names=['admission.json','system_main.cpp','native_worker.py','mame_worker.py','run_pair.py','analyze_and_freeze.py','pair_launcher.json','pair_job.json','pair_exit.json','pair_worker_exit.json','qualification.json','run61_job.json','run61_exit.json','run61_check_exit.json','run61_qualification.json','native_job.json','native_build_exit.json','native_exit.json','timing_cause_report.json']
freeze=[{'relative_path':n,'sha256':sha(HERE/n),'bytes':(HERE/n).stat().st_size} for n in freeze_names]
recovery=[{'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size} for p in [native/'ordinary_bus.csv',mame/'ordinary_rom.csv',mame/'error.log',mame/'loaded_recorder.lua']]
save('import_manifest.json',{'files':freeze,'recovery_only':recovery,'checks':checks,'one_paired61_only':True,'B16_closed':False,'physical_cause_proven':False,'immutable_terminal_evidence':True})
print(json.dumps({'checks':checks,'manifest_sha256':sha(HERE/'import_manifest.json'),'ordinary_cycle_count':len(ordinary),'case_vectors':[(c['level'],c['native_store_DS_period'],c['MAME_callback_store_period']) for c in cases]}))
