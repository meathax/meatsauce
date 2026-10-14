"""Append-only source-pinned, reference-only pickup discovery preparation."""
from pathlib import Path
import hashlib, json, re, subprocess

HERE = Path(__file__).resolve().parent
OLD = HERE.parents[1]
PREVIOUS = OLD / 'research/audio_acceptance_20261011/pickup_target'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p, value): p.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8')

assert sha(PREVIOUS/'preparation_manifest.json') == '2fe44209462e4963b48ea807d207270492a91f23efcb0d43641fdd9c50b24da7'
prior = json.loads((PREVIOUS/'preparation_manifest.json').read_text())
assert all(sha(PREVIOUS/x['path'])==x['sha256'] for x in prior['files'])
lua = (PREVIOUS/'pickup_pilot.lua').read_text()
lua = lua.replace('local states=file(', 'local consumed=file("consumed_inputs.csv","frame,screen_frame,address,data,mask,pc,time_seconds,time_attoseconds\\n")\nlocal collision=file("collision_reads.csv","frame,screen_frame,address,data,mask,pc,a0,a4,a5,d0,d1,object_hex,time_seconds,time_attoseconds\\n")\nlocal producers=file("producer_writes.csv","frame,screen_frame,address,data,mask,pc,a4,a7,stack_return,object_hex,time_seconds,time_attoseconds\\n")\nlocal states=file(',1)
insert = '''
-- Read taps pass original data unchanged; no ordinary ROM-fetch assumptions.
taps[#taps+1]=space:install_read_tap(0x80000,0x80001,"pickup_consumed_ports",function(address,data,mask)
 local t=m.time
 consumed:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d\\n",frame,screen:frame_number(),address,data,mask,cpu.state.PC.value,t.seconds,t.attoseconds));return data
end)
taps[#taps+1]=space:install_read_tap(0x20700,0x207ff,"pickup_collision_coordinates",function(address,data,mask)
 local pc=cpu.state.PC.value
 if pc>=0x53c8 and pc<=0x53e6 then
  local t=m.time;local a0=cpu.state.A0.value
  local object=(a0>=0x20420 and a0<=0x204e0) and object_hex(a0) or "outside_slots"
  collision:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d\\n",frame,screen:frame_number(),address,data,mask,pc,a0,cpu.state.A4.value,cpu.state.A5.value,cpu.state.D0.value,cpu.state.D1.value,object,t.seconds,t.attoseconds))
 end
 return data
end)
taps[#taps+1]=space:install_write_tap(0x20000,0x20fff,"pickup_producer_identity",function(address,data,mask)
 local pc=cpu.state.PC.value
 if pc>=0x5482 and pc<=0x54b6 or pc>=0x68c0 and pc<=0x6950 then
  local t=m.time;local a4=cpu.state.A4.value;local a7=cpu.state.A7.value
  local object=(a4>=0x20420 and a4<=0x204e0) and object_hex(a4) or "outside_slots"
  local ret=(a7>=0x20000 and a7<=0x20ffc) and space:read_u32(a7) or -1
  producers:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d\\n",frame,screen:frame_number(),address,data,mask,pc,a4,a7,ret,object,t.seconds,t.attoseconds))
 end
 return data
end)
'''
lua=lua.replace('local function finish(reason)',insert+'\nlocal function finish(reason)',1)
(HERE/'pickup_pilot.lua').write_text(lua,encoding='utf-8',newline='\n')
launcher='''"""One bounded official-MAME pilot. No native replay; no guest state writes."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,subprocess
HERE=Path(__file__).resolve().parent
OLD=HERE.parents[1]
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\\n',encoding='utf-8')
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--parent-release',required=True);args=ap.parse_args()
 assert args.parent_release.strip()
 manifest=json.loads((HERE/'admission_manifest.json').read_text())
 for row in manifest['files']+manifest['source_pins']:
  p=Path(row['path']);p=p if p.is_absolute() else HERE/p
  assert sha(p)==row['sha256'],str(p)
 output=HERE/'reference_pilot_v1'
 output.mkdir() # Refuse a duplicate dispatch, including after a transport failure.
 for name in ('cfg','nvram','states'):(output/name).mkdir()
 argv=[str(OLD/'tools/mame0289/mame.exe'),'kyros','-rompath',str(OLD/'roms'),'-noreadconfig','-nocheat','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(HERE/'pickup_pilot.lua'),'-pluginspath',str(OLD/'tools/mame0289/plugins'),'-seconds_to_run','55','-snapshot_directory',str(output),'-cfg_directory',str(output/'cfg'),'-nvram_directory',str(output/'nvram'),'-state_directory',str(output/'states')]
 env=os.environ.copy();env['ALPHA_CAPTURE_DIR']=str(output)
 save(output/'job.json',{'argv':argv,'cwd':str(OLD),'parent_release':args.parent_release,'manifest_sha256':sha(HERE/'admission_manifest.json'),'native_acceptance':False,'state_writes':0})
 with (output/'stdout.log').open('wb') as out,(output/'stderr.log').open('wb') as err:
  proc=subprocess.Popen(argv,cwd=OLD,env=env,stdout=out,stderr=err,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
  save(output/'started.json',{'pid':proc.pid,'time':datetime.datetime.now(datetime.timezone.utc).isoformat()});print(json.dumps({'pid':proc.pid,'output':str(output)}),flush=True)
  rc=proc.wait()
 complete=output/'complete.json';failed=(output/'failure.txt').exists()
 save(output/'exit.json',{'actual_native_exit_code':rc,'complete_present':complete.exists(),'failure_present':failed,'native_acceptance':False})
 raise SystemExit(rc or (0 if complete.exists() and not failed else 1))
if __name__=='__main__':main()
'''
(HERE/'run_reference_pilot.py').write_text(launcher,encoding='utf-8',newline='\n')
(HERE/'recipe.md').write_text('''# Ordinary pickup reference-only discovery

One official MAME 0.289 fresh boot; Kyros ROM is unchanged. Root authorization permits this reference pilot while the already-owned native 4401 replay continues. A terminal native receipt is unnecessary for reference discovery; native acceptance still requires root release and a source-qualified RTL replay.

Coin 120–126 and start 160–166 reuse the legal route. Movement begins at field 720 only with an observed player coordinate pointer, positive health and clear depletion flag. Up and Right vectors are measured for at least twelve fields; no measured motion after 48 fields ends the pilot. Approach an observed ordinary type 20/21/22/24/25; until one exists, (112,60) remains a declared exploration heuristic. Stop at candidate pickup plus 30 fields, a 150-field coordinate/room stall, or 2400 fields. No automatic extension or second pilot.

Coordinates: ROM 53be loads work base 20000 plus object word +0c, then reads two coordinate bytes. The collision arithmetic is byte wrapping: ((player-byte - item-byte + 8) & 255) < 16, i.e. -8 through +7, not inclusive +/-8. Capture pre-removal object identity and actual A0/A4/A5, D0/D1, main CPU PC and machine timestamp. Do not equate the Lua callback PC with an architectural instruction boundary without evidence. Source clear routine 68c0 must be paired with the 5482 ordinary branch return site and score writes at 20300/20370; producer 54ae queues 53 at 2035f, then accepted high-byte masked latch write at 0e0000. Script candidate alone does not qualify these semantics.

All taps return the original value unchanged. The only mutations are legal ioport field inputs. Retain events, sound IO/DAC, frame tuples, actual CPU-consumed IN0/IN1 reads, input transitions, decisions, eight complete object records per field, bounded work/sprite snapshots and completed PNGs. No screen:pixels(), RAM/CPU writes, savestate, ROM patch or forced sound command. Accepted-read timestamps preserve actual input phase; frame labels are provisional until the existing replay adapter contract is applied.

Launcher command:

```powershell
& 'D:\\vibes\\fpga\\toolchains\\msys64\\ucrt64\\bin\\python.exe' 'D:\\Arcade\\AI\\aCORES\\Alpha68k N\\research\\audio_pickup_20261011\\run_reference_pilot.py' --parent-release 'ROOT_EXACT_RELEASE_HANDLE'
```

The fixed new output directory refuses duplicate dispatch. Admission pins original preparation, official executable, ROM, disassembly and all new scripts. Inspect PID and durable receipts if transport fails. Root must approve this precise staged command before launch. No native runtime, canonical edit, Quartus, hardware or RBF is authorized here.
''',encoding='utf-8',newline='\n')
executable_lua='\n'.join(line.split('--',1)[0] for line in lua.splitlines())
checks={
 'old_preparation_immutable':True,
 'official_MAME_pin':sha(OLD/'tools/mame0289/mame.exe')=='af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3',
 'ROM_pin':sha(OLD/'roms/kyros/maincpu.bin')=='6949ea5dc91dfced8c1afccbadee18c2e795ab38d8adbc3795f05a19b8f3b2b3',
 'no_guest_state_mutations':not any(x in executable_lua for x in (':write_u',':write_direct','load_state',':pixels(')),
 'one_legal_input_setter':lua.count(':set_value(')==1,
 'finite2400': 'local frame,total=0,2400' in lua and 'frame>=total-1' in lua,
 'activation_guard':'frame>=720 and c0 and health>0 and depleted==0' in lua,
 'PNG_only':'screen:snapshot(' in lua,
 'consumed_read_passthrough':'pickup_consumed_ports' in lua,
 'PC_qualified_producer':'pickup_producer_identity' in lua,
 'no_launch_during_preparation':not (HERE/'reference_pilot_v1').exists(),
 'collision_arithmetic_all_byte_cases':all((((p-i+8)&255)<16)==(-8<=(((p-i+128)&255)-128)<=7) for p in range(256) for i in range(256)),
}
compile(launcher,str(HERE/'run_reference_pilot.py'),'exec')
checks['launcher_parse']=True
source=json.loads((PREVIOUS/'opportunity_source_stage.json').read_text())
rom=(OLD/'roms/kyros/maincpu.bin').read_bytes()
checks['retained_ROM_opcodes_match']=all(rom[int(x['pc'],16):int(x['pc'],16)+len(bytes.fromhex(x['opcode']))]==bytes.fromhex(x['opcode']) for x in source['instructions'])
save(HERE/'preparation_verification.json',{'checks':checks,'actual_exit_code':0 if all(checks.values()) else 1,'Lua_runtime_qualified':False,'reference_dispatched':False,'native_acceptance':False})
pins=[PREVIOUS/'preparation_manifest.json',OLD/'tools/mame0289/mame.exe',OLD/'roms/kyros/maincpu.bin',OLD/'sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm',PREVIOUS/'opportunity_source_stage.json']
files=[HERE/x for x in ('prepare.py','pickup_pilot.lua','run_reference_pilot.py','recipe.md','preparation_verification.json')]
save(HERE/'admission_manifest.json',{'schema':1,'scope':'One legal bounded official MAME reference pilot only; native RTL gate remains pending','files':[{'path':x.name,'sha256':sha(x),'bytes':x.stat().st_size} for x in files],'source_pins':[{'path':str(x),'sha256':sha(x),'bytes':x.stat().st_size} for x in pins],'native_acceptance':False})
print(json.dumps({'checks_passed':sum(checks.values()),'checks_total':len(checks),'manifest_sha256':sha(HERE/'admission_manifest.json'),'manifest':str(HERE/'admission_manifest.json'),'actual_exit_code':0 if all(checks.values()) else 1}))
raise SystemExit(0 if all(checks.values()) else 1)
