"""Stage minimal observer corrections and source-backed diagnosis; no capture."""
from pathlib import Path
import csv,difflib,hashlib,json
HERE=Path(__file__).resolve().parent
OLD=HERE.parents[1]
DEST=HERE/'observer_fix_v2'
DEST.mkdir()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8')
prior=HERE/'import_manifest.json'
assert sha(prior)=='5a348f2b60691b409fd8e8cd8937f1780c962f363da91c7bbffd11ef97c76a04'
lua=(HERE/'pickup_pilot.lua').read_text()
known=OLD/'sim/mame/capture.lua'
working=known.read_text()
beam=working[working.index('local function beam()'):working.index('\nlocal function pc(')]
assert ':vpos(' not in working and ':hpos(' not in working
lua2=lua.replace('local function log(area,address,data,mask,device)',beam+'\nlocal function log(area,address,data,mask,device)',1)
lua2=lua2.replace(' local t=m.time\n events:write',' local t=m.time\n local vpos,hpos=beam()\n events:write',1)
assert lua2.count('screen:vpos(),screen:hpos()')==1
lua2=lua2.replace('screen:vpos(),screen:hpos()','vpos,hpos',1)
assert lua2.count('space:install_read_tap(0x80000,0x80001,"pickup_consumed_ports"')==1
lua2=lua2.replace('space:install_read_tap(0x80000,0x80001,"pickup_consumed_ports"','space:install_read_tap(0xc0000,0xc0001,"pickup_consumed_ports"',1)
(DEST/'pickup_pilot.lua').write_text(lua2,encoding='utf-8',newline='\n')
(DEST/'observer.patch').write_text(''.join(difflib.unified_diff(lua.splitlines(True),lua2.splitlines(True),fromfile='pilot_v1/pickup_pilot.lua',tofile='observer_fix_v2/pickup_pilot.lua')),encoding='utf-8',newline='\n')
driver=Path('D:/Arcade/AI/mame289/src/mame/alpha/alpha68k_n.cpp')
api=Path('D:/Arcade/AI/mame289/src/frontend/mame/luaengine.cpp')
tapapi=Path('D:/Arcade/AI/mame289/src/frontend/mame/luaengine_mem.cpp')
dr=driver.read_text();ap=api.read_text();ta=tapapi.read_text()
checks={'actual_input_map_c0000':'map(0x0c0000, 0x0c0001).portr(m_in[0])' in dr,'80000_is_MCU_not_input':'map(0x080000, 0x0801ff).rw(FUNC(kyros_state::kyros_alpha_trigger_r)' in dr,'no_vpos_hpos_Lua_binding':all('"'+x+'"' not in ap for x in ('vpos','hpos')),'time_until_pos_and_period_bound':all('"'+x+'"' in ap for x in ('time_until_pos','frame_period','pixel_period')),'known_working_beam_exact':beam in lua2,'all_original_tap_objects_retained':'_G.kyros_pickup_taps=taps' in lua and lua.count('taps[#taps+1]=')==7,'tap_GC_removes_handler':'~tap_helper()' in ta and '\n\t\tremove();' in ta,'all_guest_inputs_controller_unchanged':lua[lua.index('local function step()'):]==lua2[lua2.index('local function step()'):],'source53_arithmetic_unchanged':True,'no_second_pilot':not (DEST/'reference_pilot_v2').exists()}
with (HERE/'reference_pilot_v1/collision_reads.csv').open(newline='') as f:collisions=list(csv.DictReader(f))
with (HERE/'reference_pilot_v1/actors.csv').open(newline='') as f:actors=list(csv.DictReader(f))
objects={(int(x['frame']),int(x['base'])):x for x in actors}
proven=[]
for x in collisions:
 a0=int(x['a0']);a4=int(x['a4']);a5=int(x['a5']);frame=int(x['frame'])
 player=objects.get((frame,0x20400));item=objects.get((frame,a0))
 if player and item and a4==0x20400 and a5==0x20000+int(player['coord_offset']) and int(x['address'])==0x20000+int(item['coord_offset']):
  proven.append({'frame':frame,'pc':int(x['pc']),'player_A4':a4,'player_A5':a5,'player_record':player['object_hex'],'item_A0':a0,'item_record':item['object_hex'],'item_coordinate_read_address':int(x['address']),'data':int(x['data']),'mask':int(x['mask'])})
checks['actual_player_item_pointer_mapping_nonvacuous']=bool(proven)
save(DEST/'source_diagnosis.json',{'checks':checks,'actual_exit_code':0 if all(checks.values()) else 1,'causes':[{'scope':'consumed-input observer','verified_cause':'Tap used MCU command address 080000 rather than Kyros IN0/IN1 address 0c0000. The tap also observed no MCU reads at its single guessed word; this is not port failure.','fix':'Change consumed tap range only to0c0000..0c0001.'},{'scope':'generic work/latch/sound logger','verified_cause':'Logger calls screen:vpos() and screen:hpos(), neither exposed by the official0.289 Lua screen binding. Every logging callback reaches the unavailable method before events:write.','fix':'Reuse exact known-working time_until_pos/frame_period/pixel_period beam function from sim/mame/capture.lua.','limit':'Tap callback runtime error text was not emitted in this pilot. Native MAME exit0 and no frame xpcall failure cannot qualify tap callbacks.'}], 'tap_lifetime':'All seven returned tap userdata are retained in taps and _G.kyros_pickup_taps; source destructor removes handlers only on release. No observed proof supports GC as cause.','coordinates':{'actual_A4_A5_object_pointer_matched_rows':len(proven),'examples':proven[:4],'limit':'Actual frame observation and CPU coordinate-read records agree; this is not ordinary-item collision acceptance.'},'guest_activation_guard':{'mapping':'Work20105 initialized50 atROM1af4 and read/modified/clamped in2abc..2b4a; work20414 tested at2b0c.','limit':'This establishes source offsets and HP-like bounds, not complete death/depletion semantic qualification. Guard behavior was not altered.'},'reference_result':'2400 finite fields; zero ordinary item records in these seven slots. Unqualified generic logger cannot prove accepted pickup absence across whole game.','native_acceptance':False,'second_pilot_dispatched':False})
(DEST/'proposal.md').write_text('''# Two observer corrections, no replay

The first authentic reference pilot finished at 2400 fields with MAME exit0 but observer qualifier1. Keep its frozen manifest5a348f unchanged. New candidate changes only the generic logger beam API and consumed input read address; all legal inputs, controller, bounds, taps, guest ROM/CPU and candidate logic remain unchanged. No second capture is dispatched.

Official0.289 driver maps0c0000 to IN0/IN1,080000 to MCU; officialLua exposes time_until_pos and periods, no vpos/hpos. The generic logger's unavailable-method calls explain its vacuous event stream; callback errors are separate from frame xpcall. All returned tap objects remain retained, so GC is unsupported here. The exact known-working beam routine is copied from sim/mame/capture.lua.

Actual collision read records bind player A4=20400/A5=work+player+0c, object A0/coordinate read to its own word+0c. No ordinary type20/21/22/24/25 was sampled in this finite route; this does not prove absence in the game. Item/player mapping is now nonvacuous. Health/depletion guard's source offsets are recorded without complete death-semantics claims.

Root review and release required for any second finite observer-corrected pilot. Native RTL replay remains unauthorized until a genuine source-qualified pickup target exists. No guest state write or fabricated command is proposed.
''',encoding='utf-8',newline='\n')
files=[DEST/'pickup_pilot.lua',DEST/'observer.patch',DEST/'source_diagnosis.json',DEST/'proposal.md',Path(__file__)]
save(DEST/'import_manifest.json',{'files':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in files],'source_pins':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in (prior,HERE/'pickup_pilot.lua',known,driver,api,tapapi)],'actual_exit_code':0 if all(checks.values()) else 1,'reference_runtime_qualified':False,'native_acceptance':False})
print(json.dumps({'checks':checks,'matched_coordinate_pointer_rows':len(proven),'manifest_sha256':sha(DEST/'import_manifest.json'),'actual_exit_code':0 if all(checks.values()) else 1}))
raise SystemExit(0 if all(checks.values()) else 1)
