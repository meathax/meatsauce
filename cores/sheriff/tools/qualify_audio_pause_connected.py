# SPDX-License-Identifier: GPL-2.0-or-later
import hashlib,json,shutil,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone
PROJECT=Path(sys.argv[1]);label=sys.argv[2]
assert label and all(c.isalnum() or c in '-_' for c in label)
ROOT=PROJECT/'_checks'/('audio-pause-connected-'+label)
ROOT.mkdir(parents=True,exist_ok=False)
for name in ['audio_pause_connected.sv','audio_pause_connected.cpp']:
 shutil.copyfile(PROJECT/'sim'/name,ROOT/name)
shutil.copyfile(Path(__file__),ROOT/'qualify.py')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
files=['rtl/n8080_mcs48.sv','rtl/vendor/t48/t48_core.v','rtl/sheriff_sn76477.sv','rtl/sheriff_sn_constants.svh']
hashes={n:sha(PROJECT/n) for n in files}
for n in files:
 p=ROOT/'sources'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(PROJECT/n,p)
rom=PROJECT/'roms/sheriff.bin';shutil.copyfile(rom,ROOT/'sheriff.bin');romhash=sha(rom)
receipt={'started_utc':datetime.now(timezone.utc).isoformat(),'source_sha256':hashes,'harness_sha256':{n:sha(ROOT/n) for n in ['audio_pause_connected.sv','audio_pause_connected.cpp','qualify.py']},'ROM_sha256':romhash,'scope':'Connected production8035/74123/SN pause preservation under finite synthetic sound-latch stimulus; no gameplay-class or fullwrapper equivalence claim.'}
save(ROOT/'launch.json',receipt)
source=ROOT/'sources';build=ROOT/'build'
command=['verilator','-Wall','-Wno-fatal','--assert','--timing','--threads','1','--x-initial','unique','--x-assign','unique','--cc','--exe','--build','-j','2','-I'+str(source/'rtl'),'-CFLAGS','-O2 -std=c++17','--top-module','audio_pause_connected','--Mdir',str(build),str(ROOT/'audio_pause_connected.sv')]+[str(source/n) for n in files[:3]]+[str(ROOT/'audio_pause_connected.cpp')]
with (ROOT/'build.log').open('wb') as log:receipt['build_exit']=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
if receipt['build_exit']==0:
 with (ROOT/'run.log').open('wb') as log:receipt['native_OS_exit']=subprocess.run([str(build/'Vaudio_pause_connected'),str(ROOT/'sheriff.bin'),str(ROOT/'native'),'+verilator+seed+1'],stdout=log,stderr=subprocess.STDOUT).returncode
 receipt['model_sha256']=sha(build/'Vaudio_pause_connected')
receipt['finished_utc']=datetime.now(timezone.utc).isoformat();receipt['changed_source']=[n for n,h in hashes.items() if sha(source/n)!=h or sha(PROJECT/n)!=h]
receipt['fixture_changed']=sha(ROOT/'sheriff.bin')!=romhash
save(ROOT/'terminal.json',receipt)
if receipt['build_exit'] or receipt.get('native_OS_exit')!=0 or receipt['changed_source'] or receipt['fixture_changed']:raise SystemExit(1)
result=json.loads((ROOT/'native/result.json').read_text())
report={'receipt':receipt,'native':result,'connected_pause_qualified':True,'whole_audio_gate_pass':False,'source_ordered_retrigger_physical_resolution':False,'current_fullwrapper_qualified':False,'limits':['Synthetic latch commands do not qualify shot/hit/death/tune gameplay classes.','132 source-ordered versus106 atomic starts remain unresolved.','Q32 analog/noise approximations and recording epoch limitations retain their existing scope.'],'evidence_sha256':{str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'launch.json',ROOT/'terminal.json',ROOT/'build.log',ROOT/'run.log',ROOT/'native/result.json']}}
save(ROOT/'sheriff_audio_pause_connected.json',report);print(json.dumps(result))
