from pathlib import Path
import hashlib,json,ast
D=Path(__file__).resolve().parent;OLD=D.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
a=json.loads((D/'preparation.json').read_text());lua=(D/'opportunity.lua').read_text();code='\n'.join(x.split('--',1)[0] for x in lua.splitlines())
assert all(x not in code for x in ['space:write','loadstate','screen:pixels'])
assert code.count('install_read_tap')==5 and code.count('install_write_tap')==7
assert 'route_phase=1' in code and 'V13_' in code and 'initial_barrier_geometry_diverged' in code
assert 'elseif target then' not in code and 'for x=48,216' not in code
assert 'sound.spaces.program:install_read_tap(0xe000' in code
assert code.count('nil')>10 and 'diagnostic_snapshot' in code
assert sha(D/'opportunity.lua')==a['lua_sha256'] and sha(D/'run_once.py')==a['worker_sha256']
for p in a['source_pins']:assert sha(Path(p['path']))==p['sha256'],p['path']
ast.parse((D/'run_once.py').read_text())
R=D/'output'
argv=[str(OLD/'tools/mame0289/mame.exe'),'kyros','-rompath',str(OLD/'roms'),'-noreadconfig','-nocheat','-skip_gameinfo','-video','none','-sound','none','-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(D/'opportunity.lua'),'-pluginspath',str(OLD/'tools/mame0289/plugins'),'-seconds_to_run','40','-samplerate','48000','-wavwrite',str(R/'production.wav'),'-snapshot_directory',str(R),'-cfg_directory',str(R/'cfg'),'-nvram_directory',str(R/'nvram'),'-state_directory',str(R/'states')]
save(D/'command.json',{'argv':argv,'cwd':str(OLD),'ALPHA_CAPTURE_DIR':str(R),'launch_count_authorized':1,'native_acceptance':False})
save(D/'preparation_failures.json',{'runtime_started':False,'corrected_preparation_errors':['V13 summary hash transcription extra d; actual file CAS corrected','Observed max movement gap15; normal95percent gap2 used with explicit finite-collision limit','Literal replacement leading whitespace adjusted to actual immutable Lua','Read-only assertion screened out comments containing screen:pixels'], 'original_pilots_unchanged':True})
files=[]
for p in sorted(D.iterdir()):
 if p.is_file():files.append({'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)})
save(D/'prepared_manifest.json',{'scope':'one official MAME legal source route; no native qualification','files':files,'source_pins':a['source_pins'],'max_fields':a['max_fields'],'bound_derivation':a['bound_derivation'],'guest_state_writes':0,'actions':'genuine coin120..126, start160..166; right-align actual xNibble10 from720; up+punch to genuine firstbarrier; eleven actual-coordinate V13 phases with punch; neutral candidate+30','decisive_preparation_verification':True})
print(json.dumps({'prepared_manifest_sha256':sha(D/'prepared_manifest.json'),'preparation_sha256':sha(D/'preparation.json'),'lua_sha256':sha(D/'opportunity.lua'),'command_sha256':sha(D/'command.json'),'max_fields':a['max_fields'],'actual_exit_code':0}))
