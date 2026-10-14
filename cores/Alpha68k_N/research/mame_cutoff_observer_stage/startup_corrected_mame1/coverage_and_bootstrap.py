from pathlib import Path
import csv,json,hashlib,collections,itertools
HERE=Path(__file__).resolve().parent;OUT=HERE/'bootstrap_coverage';OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def rows(p):
 with p.open(newline='')as f:return list(csv.DictReader(f))
def save(name,obj):(OUT/name).write_text(json.dumps(obj,indent=2)+'\n')
assert not OUT.exists();OUT.mkdir()
field=OLD/'sim/captures/rtl/irq_startup_phase1';long=OLD/'sim/captures/rtl/irq_sampling_edge_latch61';mame=OLD/'sim/captures/kyros/mame_cutoff_observer61'
short=rows(field/'bus.csv');retained=rows(long/'bus.csv')
assert short==retained[:len(short)]
stats=collections.Counter((r['address'],r['rw'],r['data_in'])for r in short)
work=[r for r in retained if int(r['rw'])==0 and 0x20000<=int(r['address'])<0x21000]
events=rows(mame/'events.csv');mw=[r for r in events if r['area']=='work']
joined=[]
for n,m in zip(work[:16],mw[:16]):
 joined.append({'native':n,'MAME':m,'address_data_order_equal':int(n['address'])==int(m['address'])and int(n['data_out'])==int(m['data']),'MAMEcallback_minus_nativeaccept':int(m['master_ticks'])-int(n['tick'])})
host=HERE.parent/'startup_proposal_v2/system_main.cpp'
report={'firstfield_native':{'bus':pin(field/'bus.csv'),'rowcount':len(short),'first':short[0],'last':short[-1],'transaction_sequence_contiguous':[int(r['transaction'])for r in short]==list(range(1,len(short)+1)),'distinct_address_rw_data_counts':[{'address':int(k[0]),'rw':int(k[1]),'data':int(k[2]),'count':v}for k,v in stats.items()],'frame_summary':rows(field/'frames.csv'),'instruction_rows':len(rows(field/'instruction_events.csv')),'epoch_rows':len(rows(field/'epoch_events.csv')),'bus_records_PC':False,'bus_records_AS_or_CPUcapture':False,'bus_boundary':'Post-clock main_transactions increment; address/attrs/dout sampled pre-edge, board din sampled post-edge. This is board acceptance, not AS or CPU capture. AS relation qualified only for2048startup observer and late ordinary61window.'},'host_logging_contract':{'source':pin(host),'first_4096_global_transfers':True,'then_only_selected_extra2048':'address020000..020fff,080000..0801ff,01fc00..01feff','PC_IR_IRD_only_frames59_60':True,'source_lines':[325,345]},'first_post_boot_work_join':joined,'earliest_retained_work':work[0]if work else None,'earliest_MAME_work':mw[0]if mw else None,'retained_bus_counts':{'total':len(retained),'workwrites':len(work),'MAME_workevents':len(mw)},'boot_words_from_genuine_reads':{'0400':'323c MOVE.W immediate,D1','0402':'4000 immediateD1=16384','0404':'1039 MOVE.B absolute-long,D0','0406':'0006 highaddress','0408':'0000 lowaddress ->60000watchdog','040a':'51c9 DBRA D1','040c':'fff8 displacement ->404'},'coverage_decision':'A second MAME-only firstfield fullROM observation does not reach DBRA expiry/bootstrap transitions and cannot locate additional24ticks. Existing field0 acceptedbus stops142k and remains unchanged26CPUcycle bootdelay iterations; completedfield0stillloops. No new capture is proposed until native transition coverage exists or an exact retained source contract closes it.','initial_offset':{'MAMEcallback_minus_native_AS':-42,'MAMEcallback_minus_nativeaccept':-43,'qualified_commonrows':57},'late_offset':{'MAMEcallback_minus_native_AS':-66,'evidence':pin(HERE.parent/'ordinary61/import_manifest.json')},'source_scope_only':True,'guest_jobs_launched':0,'B16_closed':False}
save('report.json',report);save('import_manifest.json',{'files':[pin(OUT/'report.json'),pin(Path(__file__))],'raw_recovery':[pin(field/'bus.csv'),pin(long/'bus.csv'),pin(mame/'events.csv')],'B16_closed':False})
print(json.dumps({'manifest':pin(OUT/'import_manifest.json'),'firstfieldrows':len(short),'lasttick':short[-1]['tick'],'field0':report['firstfield_native']['frame_summary'],'firstworkjoins':joined[:4],'all16joined':all(x['address_data_order_equal']for x in joined),'join_deltas':[x['MAMEcallback_minus_nativeaccept']for x in joined],'no_newcapture':True}))
