from pathlib import Path
import csv,json,hashlib,collections
HERE=Path(__file__).resolve().parent;OUT=HERE/'retained_write_intervals';OLD=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)}
def rows(p):
 with p.open(newline='')as f:return list(csv.DictReader(f))
def excerpt(p,a,b):return [{'line':i,'text':s}for i,s in enumerate(p.read_text().splitlines(),1)if a<=i<=b]
assert not OUT.exists();OUT.mkdir()
np=OLD/'sim/captures/rtl/irq_sampling_edge_latch61/bus.csv';mp=OLD/'sim/captures/kyros/mame_cutoff_observer61/events.csv';ip=mp.parent/'cpu_space_iack.csv'
nr=[r for r in rows(np)if int(r['rw'])==0 and 0x20000<=int(r['address'])<0x21000]
mr=[r for r in rows(mp)if r['area']=='work'];ir=rows(ip)
prefix=[];first_mismatch=None
for index,(n,m)in enumerate(zip(nr,mr)):
 mask=(0xff00 if int(n['uds_n'])==0 else 0)|(0xff if int(n['lds_n'])==0 else 0)
 equal=int(n['address'])==int(m['address'])and mask==int(m['mask'])and(int(n['data_out'])&mask)==(int(m['data'])&mask)
 if not equal:first_mismatch={'index':index,'native':n,'MAME':m};break
 prefix.append({'index':index,'address':int(n['address']),'data':int(n['data_out'])&mask,'mask':mask,'native_tick':int(n['tick']),'MAME_callback_tick':int(m['master_ticks']),'MAMEinstruction_pc':int(m['instruction_pc']),'MAMEframe':int(m['frame']),'delta_callback_minus_native_accept':int(m['master_ticks'])-int(n['tick'])})
changes=[];prev=None
for r in prefix:
 if r['delta_callback_minus_native_accept']!=prev:changes.append(r);prev=r['delta_callback_minus_native_accept']
intervals=[]
for a,b,c in zip(prefix,prefix[1:],prefix[2:]):
 if a['mask']==b['mask']==c['mask']==65535 and b['address']==a['address']-4 and c['address']==a['address']-2:
  callbacks=[x for x in ir if a['MAME_callback_tick']<int(x['master_ticks'])<b['MAME_callback_tick']]
  if len(callbacks)!=1:continue
  intervals.append({'PClo_write':a,'SR_write':b,'PChi_write':c,'genuine_MAME_IACK_inside_write_interval':callbacks[0],'native_PClo_accept_to_SR_accept_ticks':b['native_tick']-a['native_tick'],'MAME_PClo_callback_to_SR_callback_ticks':b['MAME_callback_tick']-a['MAME_callback_tick'],'native_excess_ticks':(b['native_tick']-a['native_tick'])-(b['MAME_callback_tick']-a['MAME_callback_tick'])})
host=HERE.parent/'startup_proposal_v2/system_main.cpp';sdf=Path(r'D:\Arcade\AI\mame289\src\devices\cpu\m68000\m68000-sdf.cpp')
txt=host.read_text();e_window_line=next((i for i,s in enumerate(txt.splitlines(),1)if 'bool e_window' in s),None)
report={'strict_matched_prefix_rows':len(prefix),'native_available_work_writes':len(nr),'MAME_work_events':len(mr),'first_mismatch':first_mismatch,'exact_address_mask_data_order_prefix':prefix,'changes_in_callback_minus_accept':changes,'source_qualified_irq_stack_intervals':intervals,'boundary_contract':'Native observedboardacceptance and MAME nil-write callback are distinct. Consecutive matchedwordwrites on identicalRAM/buslanes let their elapsedinterval difference eliminate epoch offset, but no nativeAS/CPUcapture is retained at these firstIRQs. Do not promote a writeabsoluteoffset to ROMreadphase.', 'source':[{'pin':pin(sdf),'interrupt_stack_and_IACK_microsteps':excerpt(sdf,739,850)},{'pin':pin(host),'e_window_definition':excerpt(host,e_window_line,e_window_line)if e_window_line else None,'trace_contract':excerpt(host,325,349)}],'supersedes_initial_iack_scope':'initial_iack_source captures firstretainednativeIACK at47849609 inframe59, but lists firstglobalMAMEIACK45732719 frame56. These lists are notmatched; no firstIRQphaseclaim is permitted from that report. Matching writeintervals here use actual sameorder/data/masks and MAMEIACK genuinelybetweenPClo/SR.', 'supersedes_bootstrap_sources_prose':'PC7d6 is MOVE #2000,SR. PendinghardwareIRQ entersbefore7da, notsoftwareTRAP; stackinterpretation comesfrom pinnedROM+interruptmicrosteps+actualIACKrecord betweenwrites.', 'capture_proposal':'Not prepared: firstfieldacceptedtrace stops142058 whilecompletedfield0 remainsbootstrap400..40c. ActualfirstIRQat45732xxx field56 lacksnativeAS/PC/IRcapture. A MAME-onlyfirstfieldcapture cannotlocate alladditional24ticks. Use retained source-qualifiedwriteintervals; if still needed a futureobserver must target uncoveredIRQ transition with exactnativecoverage, separatelyrootreleased.', 'initial_ROM_callback_minus_AS':-42,'late_ROM_callback_minus_AS':-66,'additional24_localized_only_if_source_intervals_cover_it':False,'no_CPUclock_IRQpatch':True,'new_guest_jobs':0,'B16_closed':False}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
(OUT/'import_manifest.json').write_text(json.dumps({'files':[pin(OUT/'report.json'),pin(Path(__file__))],'raw_evidence':[pin(np),pin(mp),pin(ip)],'prior_coverage':[pin(HERE/'bootstrap_coverage/import_manifest.json'),pin(HERE/'bootstrap_sources/import_manifest.json')],'B16_closed':False},indent=2)+'\n')
print(json.dumps({'manifest':pin(OUT/'import_manifest.json'),'strict_prefix_rows':len(prefix),'first_mismatch':first_mismatch,'delta_changes':changes,'IRQintervals':[{'frame':x['PClo_write']['MAMEframe'],'native_lowPCtick':x['PClo_write']['native_tick'],'native_elapsed':x['native_PClo_accept_to_SR_accept_ticks'],'MAME_elapsed':x['MAME_PClo_callback_to_SR_callback_ticks'],'excess':x['native_excess_ticks'],'MAME_IACK':x['genuine_MAME_IACK_inside_write_interval']}for x in intervals],'e_window_source':report['source'][1]['e_window_definition'],'no_new_capture':True}))
