"""Qualify actual completed build/API and freeze runtime commands, never run games."""
from pathlib import Path
import hashlib,json,subprocess,time
ROOT=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
HERE=Path(__file__).resolve().parent/'paired601'
SRC=HERE/'source'
def pin(p): return dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
exit=json.loads((HERE/'build_exit.json').read_text())
assert exit['exit_code']==0,exit
buildroot=(SRC/'sim/build/wsl_system_build_dir.txt').read_text().strip()
assert buildroot.startswith('/tmp/alpha68kn-system.') and ' ' not in buildroot
guest_code='''from pathlib import Path
import hashlib,json,sys
r=Path(sys.argv[1]);h=r/'obj/Valpha68kn_system___024root.h';t=h.read_text()
names=['work_port_addr','work_write_hi','work_write_lo','work_data_hi','work_data_lo','ram_bus_service','cpu_phase','phase','pswS','psw','rFC','Ir','Ird','regs68H','regs68L','PcH','PcL']
lines={n:[x.strip() for x in t.splitlines() if '__DOT__'+n+';' in x or '__DOT__'+n+'[' in x] for n in names}
files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in r.iterdir() if p.is_file()}
print(json.dumps(dict(header_sha256=hashlib.sha256(h.read_bytes()).hexdigest(),members=lines,files=files,ELF_sha256=hashlib.sha256((r/'obj/alpha68kn_system_sim').read_bytes()).hexdigest())))
'''
observed=subprocess.run(['wsl.exe','-d','Ubuntu','--exec','/usr/bin/python3','-c',guest_code,buildroot],capture_output=True,text=True)
assert observed.returncode==0,observed.stderr
guest=json.loads(observed.stdout)
assert all(guest['members'].values()),guest['members']
assert any('18' in x for x in guest['members']['regs68H'])
assert any('18' in x for x in guest['members']['regs68L'])
assert guest['ELF_sha256']==exit['ELF']['sha256']
expected=[]
for p in SRC.rglob('*'):
    if p.is_file() and p.suffix in ['.sv','.v'] and p.name in guest['files']:
        assert pin(p)['sha256']==guest['files'][p.name],str(p)
        expected.append(pin(p))
assert len(expected)==67,len(expected)
for p in [SRC/'sim/system_main.cpp',SRC/'sim/sdram_model.h',SRC/'sim/upper_ram_observer.vlt']:
    assert guest['files'][p.name]==pin(p)['sha256']
proof=dict(actual_native_build_exit=0,build_exit=pin(HERE/'build_exit.json'),guest_root=buildroot,
    actual_guest_HDL_count=67,all_67_guest_RTL_bytes_match_staged_candidate=True,
    actual_ELF_matches_guest=True,ELF=exit['ELF'],generated_API=guest['members'],header_sha256=guest['header_sha256'],
    exact_source_flags='Verilator5.050; -j4 -O3 --assert --no-assert-case -Wno-fatal; additive public_flat_rd configuration only',
    guest_source_pins=expected,source_preparation=pin(HERE/'preparation_native_build.json'),
    native_PC_meaning='PcH/PcL is observed PC state; not alone a guarantee of writer instruction, IR/IRD/FC and pre/post values retained.',
    readonly=True,runtime_release=False,qualified_at=time.time())
(HERE/'native_API_qualification.json').write_text(json.dumps(proof,indent=2)+'\n')
native=['wsl.exe','-d','Ubuntu','--cd',str(SRC/'sim/build'),'--exec','./alpha68kn_system_sim',
    '/mnt/d/Arcade/AI/aCORES/Alpha68k N/roms/kyrosj/download.bin','601',
    '/mnt/d/Arcade/AI/aCORES/Alpha68k N/research/japan_ram_divergence_20261011/paired601/native_capture',
    'gameplay','dac-probe','--inputs','/mnt/d/Arcade/AI/aCORES/Alpha68k N/sim/captures/kyrosj/gameplay/frame_states.csv']
mameexe=ROOT/'tools/mame0289/mame.exe'
assert pin(mameexe)['sha256']=='af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3'
capture=HERE/'mame_capture'
mame=[str(mameexe),'kyrosj','-rompath',str(ROOT/'roms'),'-noreadconfig','-skip_gameinfo','-video','none','-sound','none',
    '-nothrottle','-noautoframeskip','-frameskip','0','-autoboot_delay','0','-autoboot_script',str(HERE/'mame_observer.lua'),
    '-pluginspath',str(ROOT/'tools/mame0289/plugins'),'-seconds_to_run','20',
    '-snapshot_directory',str(capture),'-cfg_directory',str(capture/'cfg'),'-nvram_directory',str(capture/'nvram'),
    '-state_directory',str(capture/'states'),'-wavwrite',str(capture/'audio.wav')]
ps=subprocess.run(['wsl.exe','-d','Ubuntu','--exec','/bin/ps','-eo','pid,args'],capture_output=True,text=True)
assert ps.returncode==0,ps.stderr
lines=[x for x in ps.stdout.splitlines() if 'alpha68kn_system_sim' in x and 'japan_ram_divergence_20261011/paired601/native_capture' in x]
assert not lines,lines
windows=subprocess.run(['powershell.exe','-NoProfile','-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(mame|python|wsl)\\.exe$' -and $_.CommandLine -like '*paired601*' } | Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress"],
    capture_output=True,text=True)
assert windows.returncode==0,windows.stderr
commands=dict(scope='Prepared commands only; root release required before paired runtime.',
    native_command=native,MAME_command=mame,MAME_environment=dict(ALPHA_CAPTURE_DIR=str(capture),ALPHA_CAPTURE_MODE='gameplay',ALPHA_CAPTURE_FRAMES='601'),
    MAME_binary=pin(mameexe),MAME_observer=pin(HERE/'mame_observer.lua'),MAME_API=pin(HERE/'mame_API_preparation.json'),
    native_API=pin(HERE/'native_API_qualification.json'),input_reference=pin(ROOT/'sim/captures/kyrosj/gameplay/frame_states.csv'),
    ROM=pin(ROOT/'roms/kyrosj/download.bin'),original_reference_import=pin(ROOT/'research/remaining_gates_20261011/japan_joined720/canonical_v2_import_manifest.json'),
    pre_admission=dict(time=time.time(),owned_native_matches=lines,owned_native_ps_exit=ps.returncode,
        windows_process_scan=windows.stdout.strip(),note='Qualifying observer process may list itself; no game runtime has been launched. Repeat exact ownership scan at release admission.'),
    qualification_order=['Actual native/MAME exits and complete601 outputs','Native existingjoined720 RGB/work/strip/audio/input prefix invariant',
        'OfficialMAME original completedPNG/work/strip/ports/audio overlap invariant','Paired strictRGB/strip/work comparisons','ArchitecturalSP and lastwriter diagnosis'],
    never_loosen_strict_work=True,runtime_release=False)
(HERE/'paired601_commands_admission_preparation.json').write_text(json.dumps(commands,indent=2)+'\n')
print(json.dumps(dict(actual_build_exit=0,guest_HDL=67,ELF=exit['ELF']['sha256'],API=pin(HERE/'native_API_qualification.json'),
    commands=pin(HERE/'paired601_commands_admission_preparation.json'),owned_native_runtime_matches=len(lines),runtime_released=False),indent=2))
