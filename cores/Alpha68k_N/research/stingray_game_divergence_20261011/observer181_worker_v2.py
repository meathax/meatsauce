import ast,csv,hashlib,json,os,re,shutil,subprocess,sys,time
from pathlib import Path
O=Path(__file__).resolve().parent
BASE=O.parent/'stingray_combined_stage/next_coupled_scope_v2'
S=O/'native_observer181/source';JOB=O/'native_observer181'
PREV=O/'corrected181/capture'
REF=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/sim/captures/sstingry/gameplay')
ROM=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/roms/sstingry/download.bin')
INPUT=O/'gameplay_inputs_after_snapshot.csv'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':sha(p),'bytes':p.stat().st_size}
def save(p,d):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(d,indent=2)+'\n')
def wsl(p):return '/mnt/'+str(p.drive)[0].lower()+str(p)[2:].replace('\\','/')
def prepare():
 assert not (JOB/'preparation.json').exists(),'Duplicate preparation refused'
 shutil.copytree(BASE/'source',S,ignore=shutil.ignore_patterns('build'),dirs_exist_ok=True)
 host=S/'sim/system_main.cpp';original=host.read_text()
 src=(S/'rtl/vendor/t48/t48_core.v').read_text()
 modules={n:b for n,b in re.findall(r'module\s+(\w+)(.*?)endmodule',src,re.S)}
 def route(kind,seen=()):
  if kind=='t48_cond_branch':return []
  for sub,inst in re.findall(r'\b(t48_\w+)\s+(\w+)\s*\(\s*\.',modules[kind]):
   if sub in seen:continue
   child=route(sub,seen+(kind,))
   if child is not None:return [inst]+child
  return None
 wrapper=(S/'rtl/alpha68kn_mcu.sv').read_text()
 core=re.search(r'\bt48_core\s+(\w+)\s*\(',wrapper).group(1)
 branch_route=route('t48_core');assert branch_route is not None
 prefix='alpha68kn_system__DOT__board__DOT__sting_mcu__DOT__'+core+'__DOT__'+'__DOT__'.join(branch_route)+'__DOT__'
 names=['en_clk_i','compute_take_i','branch_cond_i','t0_i','t1_i','take_branch_o']
 vlt=S/'sim/coupled_observer.vlt'
 vlt.write_text(vlt.read_text()+''.join('public_flat_rd -module "t48_cond_branch" -var "'+n+'"\n' for n in names))
 needle='    std::ofstream mcu_events(output/"coupled_mcu.csv");'
 replacement='''    std::ofstream accepted_inputs(output/"accepted_inputs.csv"), coin_samples(output/"coin_samples.csv");
    accepted_inputs<<"tick_relative,tick_absolute,frame,raster_x,raster_y,address,iack,rw,uds_n,lds_n,data_out,data_in_before,data_in_after,controls,coins_n,main_pc,main_ir,main_ird,mcu_control,mcu_bus,irq2_held\\n";
    coin_samples<<"tick_relative,tick_absolute,frame,program_addr,branch_cond,t0_sample,t1_sample,take_before,take_after,controls,coins_n\\n";
    uint64_t run_origin=0;
'''+needle
 assert original.count(needle)==1
 changed=original.replace(needle,replacement)
 changed=changed.replace('    const uint64_t started=ticks;','    const uint64_t started=ticks;run_origin=started;')
 needle='        tick();\n        if(top.audio_sample_ce) {'
 sampling='''        auto *coin_state=top.rootp;
        bool consume_coin=frame>=119 && frame<=169 && coin_state->PREFIXen_clk_i && coin_state->PREFIXcompute_take_i;
        auto branch_condition=coin_state->PREFIXbranch_cond_i;
        auto sampled_t0=coin_state->PREFIXt0_i,sampled_t1=coin_state->PREFIXt1_i;
        auto take_before=coin_state->PREFIXtake_branch_o;
        auto program_before=coin_state->alpha68kn_system__DOT__board__DOT__sting_mcu_program_addr;
        tick();
        if(consume_coin) coin_samples<<ticks-started<<','<<ticks<<','<<frame<<','<<program_before<<','<<unsigned(branch_condition)<<','<<unsigned(sampled_t0)<<','<<unsigned(sampled_t1)<<','<<unsigned(take_before)<<','<<unsigned(coin_state->PREFIXtake_branch_o)<<','<<top.controls<<','<<unsigned(top.coins_n)<<'\\n';
        if(top.audio_sample_ce) {'''.replace('PREFIX',prefix)
 assert changed.count(needle)==1
 changed=changed.replace(needle,sampling)
 needle='            previous=top.main_transactions;'
 capture='''            if(frame>=119 && frame<=169 && ((attrs&8) || address==0x0c0000 || (address>=0x20040 && address<=0x20060) || (address>=0x80000 && address<0x80200))) {
                auto *r=top.rootp;
                uint32_t pc=(uint32_t(r->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__PcH)<<16)|r->alpha68kn_system__DOT__board__DOT__maincpu__DOT__excUnit__DOT__PcL;
                accepted_inputs<<ticks-started<<','<<ticks<<','<<frame<<','<<raster_x<<','<<raster_y<<','<<address<<','<<((attrs>>3)&1)<<','<<((attrs>>2)&1)<<','<<((attrs>>1)&1)<<','<<(attrs&1)<<','<<dataout<<','<<instruction_din_before<<','<<top.debug_main_din<<','<<top.controls<<','<<unsigned(top.coins_n)<<','<<pc<<','<<r->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Ir<<','<<r->alpha68kn_system__DOT__board__DOT__maincpu__DOT__Ird<<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_control)<<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__sting_mcu_bus)<<','<<unsigned(r->alpha68kn_system__DOT__board__DOT__irq2)<<'\\n';
            }
'''+needle
 assert changed.count(needle)==2
 host.write_text(changed.replace(needle,capture,1))
 closure=json.loads((BASE/'source_closure.json').read_text());checked=[]
 for old in closure['source_files']:
  origin=Path(old['path']);rel=origin.relative_to(BASE/'source');target=S/rel
  assert sha(origin)==old['combined_sha256']
  changed_ok=str(rel).replace('\\','/') in ['sim/system_main.cpp','sim/coupled_observer.vlt']
  if not changed_ok:assert sha(target)==old['combined_sha256']
  checked.append({'relative':str(rel),'original':old['combined_sha256'],'observer':sha(target),'functional_source_unchanged':not changed_ok})
 (JOB/'host_observer.patch').write_text(''.join(__import__('difflib').unified_diff(original.splitlines(True),host.read_text().splitlines(True),fromfile='original/system_main.cpp',tofile='observer/system_main.cpp')))
 lua=Path('D:/Arcade/AI/aCORES/Alpha68k N/sim/mame/capture.lua');text=lua.read_text();assert sha(lua)=='174ed050b8776e11745dfb0211ee42995e582c91f9a5f110665663f368ab8c6c'
 readtaps='''local diagnostic_snapshot = false
local accepted_reads = open("accepted_reads.csv")
accepted_reads:write("frame,screen_frame,raster_y,raster_x,address,data,mask,main_pc,in0,in1,in2,mcu_pc\\n")
local observed_mcu = machine.devices[":alpha8511"] or machine.devices[":mcu"]
local function accepted_read(a,d,m)
    if diagnostic_snapshot or frame<119 or frame>169 then return end
    local y,x=beam()
    local mpc = observed_mcu and pc(observed_mcu) or -1
    accepted_reads:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\\n",frame,screen:frame_number(),y,x,a,d,m,pc(main),ports.IN0:read(),ports.IN1:read(),ports.IN2:read(),mpc))
    accepted_reads:flush()
end
handles[#handles+1]=space:install_read_tap(0x0c0000,0x0c0001,"alpha_actual_input_read",accepted_read)
handles[#handles+1]=space:install_read_tap(0x020040,0x020061,"alpha_actual_reply_read",accepted_read)
handles[#handles+1]=space:install_read_tap(0x080000,0x0801ff,"alpha_actual_command_read",accepted_read)
handles[#handles+1]=space:install_read_tap(0x000060,0x00007f,"alpha_actual_IACK_vector",accepted_read)
'''
 needle='-- Retain subscriptions and taps until the machine exits.';assert needle in text
 text=text.replace(needle,readtaps+'\n'+needle)
 needle='if sample_frames[frame] or frame == total-1 then snapshot() end';assert needle in text
 text=text.replace(needle,'if sample_frames[frame] or frame == total-1 then diagnostic_snapshot=true;snapshot();diagnostic_snapshot=false end')
 (JOB/'observer_capture.lua').write_text(text)
 save(JOB/'preparation.json',{'branch_hierarchy':prefix,'qualified_original_source_files':checked,'original_recorder':pin(lua),'observer_recorder':pin(JOB/'observer_capture.lua'),'observer_host':pin(host),'observer_config':pin(vlt),'input':pin(INPUT),'ROM':pin(ROM),'functional_RTL_changed':False,'extra_observer_exports':names,'authorization':'Root task permits one host/read-only debug181 replay and one official read-tap181 capture.'})
def start(cmd,kind,env=None):
 log=(JOB/(kind+'.log')).open('wb');p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,env=env)
 save(JOB/(kind+'_job.json'),{'pid':p.pid,'worker_pid':os.getpid(),'started':time.time(),'command':cmd});return p,log
def finish(pair,kind):
 p,log=pair;code=p.wait();log.close();save(JOB/(kind+'_exit.json'),{'exit_code':code,'pid':p.pid,'worker_pid':os.getpid(),'finished':time.time(),'log':pin(JOB/(kind+'.log'))});return code
def worker():
 prepare()
 md=json.loads((REF/'manifest.json').read_text());cmd=ast.literal_eval(md['command']) if isinstance(md['command'],str) else md['command']
 exe=Path(cmd[0]);assert sha(exe)=='af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'
 mr=JOB/'mame181';mr.mkdir()
 for opt,dest in [('-autoboot_script',JOB/'observer_capture.lua'),('-snapshot_directory',mr),('-cfg_directory',mr/'cfg'),('-nvram_directory',mr/'nvram'),('-state_directory',mr/'states'),('-wavwrite',mr/'audio.wav')]:cmd[cmd.index(opt)+1]=str(dest)
 env=os.environ.copy();env.update({'ALPHA_CAPTURE_DIR':str(mr),'ALPHA_CAPTURE_MODE':'gameplay','ALPHA_CAPTURE_FRAMES':'181'})
 save(JOB/'reference_pins.json',{'official_exe':pin(exe),'original_reference_manifest':pin(REF/'manifest.json'),'script':pin(JOB/'observer_capture.lua')})
 ref=start(cmd,'mame181',env)
 build=start(['wsl.exe','-d','Ubuntu','--cd',str(S),'--exec','/bin/bash','sim/build_system.sh'],'build')
 code=finish(build,'build');refcode=finish(ref,'mame181')
 assert code==0 and refcode==0
 elf=S/'sim/build/alpha68kn_system_sim';save(JOB/'ELF.json',pin(elf))
 run=start(['wsl.exe','-d','Ubuntu','--cd',str(elf.parent),'--exec','/bin/bash','-c','printf "linux_pid=%s\\n" "$$"; exec "$@"','observer181','./alpha68kn_system_sim',wsl(ROM),'181',wsl(JOB/'capture'),'gameplay','--inputs',wsl(INPUT)],'run')
 assert finish(run,'run')==0
 verify()
def verify():
 overlaps=[]
 for n in sorted(PREV.glob('frame_*')):
  other=JOB/'capture'/n.name;assert other.exists();eq=sha(n)==sha(other);overlaps.append({'name':n.name,'exact':eq,'baseline_sha256':sha(n),'observer_sha256':sha(other)})
 assert all(x['exact'] for x in overlaps)
 assert sha(PREV/'applied_inputs.csv')==sha(JOB/'capture/applied_inputs.csv')
 refs=[]
 for f in [0,30,90,119,179]:
  for suffix in ['png','work.bin','sprites.bin']:
   a=REF/f'frame_{f:06d}.{suffix}';b=JOB/f'mame181/frame_{f:06d}.{suffix}';eq=sha(a)==sha(b);refs.append({'name':a.name,'exact':eq,'original_sha256':sha(a),'observer_sha256':sha(b)})
 assert all(x['exact'] for x in refs)
 original=(REF/'frame_states.csv').read_text().splitlines()[:182];new=(JOB/'mame181/frame_states.csv').read_text().splitlines();assert original==new
 for kind in ['build','mame181','run']:assert json.loads((JOB/(kind+'_exit.json')).read_text())['exit_code']==0
 with (JOB/'capture/accepted_inputs.csv').open() as f:native=list(csv.DictReader(f))
 with (JOB/'mame181/accepted_reads.csv').open() as f:mame=list(csv.DictReader(f))
 with (JOB/'capture/coin_samples.csv').open() as f:coin=list(csv.DictReader(f))
 assert native and mame and coin
 save(JOB/'verification.json',{'native_all_snapshot_overlap':overlaps,'native_applied_inputs_exact':True,'reference_all5_completedPNG_RAM_exact':refs,'reference_all181_frame_states_exact':True,'actual_exits':{k:0 for k in ['build','mame181','run']},'native_accepted_rows':len(native),'reference_read_rows':len(mame),'T48_branch_sample_rows':len(coin),'functional_RTL_changed':False,'whole_game_pass':False})
 save(JOB/'verification_exit.json',{'exit_code':0,'finished':time.time(),'worker_pid':os.getpid()})
 print('Observer invariance verified: native',len(overlaps),'snapshot artifacts; paired actual accepted reads',len(native),len(mame),'T48 samples',len(coin))
if __name__=='__main__':
 if '--worker' in sys.argv:
  try:worker()
  except Exception as e:save(JOB/'worker_failure.json',{'type':type(e).__name__,'message':str(e),'finished':time.time(),'pid':os.getpid()});raise
 elif '--verify' in sys.argv:verify()
 else:
  assert not (JOB/'worker_v2.json').exists(),'Duplicate worker refused';JOB.mkdir(exist_ok=True)
  with (JOB/'worker.log').open('wb') as log:p=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--worker'],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW|subprocess.CREATE_NEW_PROCESS_GROUP)
  save(JOB/'worker_v2.json',{'pid':p.pid,'started':time.time(),'helper':pin(Path(__file__))});print('Observer worker registered',p.pid)
