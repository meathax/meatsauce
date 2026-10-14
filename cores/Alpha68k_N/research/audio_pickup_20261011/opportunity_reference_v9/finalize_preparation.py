from pathlib import Path
import hashlib,json,importlib.util
D=Path(__file__).resolve().parent;OLD=D.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
p=D/'opportunity.lua';s=p.read_text();assert sha(p)=='c8990e49e0011444ac09f8c1f2901cad5b4feb79ff17dec4b584ee74d9a937ad'
s=s.replace('local handles={}','local handles={}\nlocal diagnostic_snapshot=false')
s=s.replace('local pc=cpu.state.PC.value\n  if pc>=0x53c8','local pc=cpu.state.PC.value\n  if not diagnostic_snapshot and pc>=0x53c8')
s=s.replace('local pc=cpu.state.PC.value\n if pc>=0xb902','local pc=cpu.state.PC.value\n if not diagnostic_snapshot and pc>=0xb902')
s=s.replace('local pre=space:read_u16(address);local pc=cpu.state.PC.value','local previous_guard=diagnostic_snapshot;diagnostic_snapshot=true;local pre=space:read_u16(address);diagnostic_snapshot=previous_guard;local pc=cpu.state.PC.value')
s=s.replace('local pc=cpu.state.PC.value\n tile_writes:write','local pc=cpu.state.PC.value\n local previous_guard=diagnostic_snapshot;diagnostic_snapshot=true;local pre=space:read_u16(address);diagnostic_snapshot=previous_guard\n tile_writes:write')
s=s.replace('pc,space:read_u16(address),cpu.state.A0.value','pc,pre,cpu.state.A0.value')
s=s.replace('local ok,err=xpcall(step,debug.traceback)','diagnostic_snapshot=true;local ok,err=xpcall(step,debug.traceback);diagnostic_snapshot=false')
p.write_text(s,encoding='utf-8',newline='\n')
a=json.loads((D/'preparation.json').read_text());a['lua_sha256']=sha(p)
for name,expected in [('tools/mame0289/mame.exe','af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'),('roms/kyros/maincpu.bin','6949ea5dc91dfced8c1afccbadee18c2e795ab38d8adbc3795f05a19b8f3b2b3'),('sim/captures/diagnostics/kyros_rom_disassembly/maincpu.asm','da4e0ed81c446f9c77107fbac9e30f950d7e4cce20f2285fe78f14115f8d707d')]:
 q=OLD/name;assert sha(q)==expected;a['source_pins'].append({'path':str(q),'sha256':expected})
a['observer_guard']='diagnostic_snapshot suppresses read-tap records for frame/snapshot and write-tap preword reads; intended writes remain unchanged'
(D/'preparation.json').write_text(json.dumps(a,indent=2)+'\n')
print(json.dumps({'lua_sha256':a['lua_sha256'],'preparation_sha256':sha(D/'preparation.json'),'available_lua_packages':{x:importlib.util.find_spec(x) is not None for x in ['lupa','luaparser']}}))
