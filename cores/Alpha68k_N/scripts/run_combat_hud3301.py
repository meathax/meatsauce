"""Collect real CPU HUD writes/RAM at all six retained combat mismatches."""
from pathlib import Path
import csv, hashlib, json, os, shutil, subprocess, time, wave

ROOT = Path(__file__).resolve().parents[1]
NAME = 'kyros_combat_hud3301'
OUT = ROOT / 'sim/captures/rtl' / NAME
BASE = ROOT / 'sim/captures/rtl/kyros_combat3600'
REF = ROOT / 'sim/captures/kyros/combat3600_v2'
if os.name != 'posix' or not str(ROOT).startswith('/mnt/d/'):
    raise SystemExit('Run explicitly through Ubuntu WSL')
if OUT.exists() or (ROOT / 'research' / f'{NAME}_job.json').exists():
    raise SystemExit('Refusing to overwrite an existing capture or job')
OUT.mkdir(parents=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(suffix, value):
    (ROOT / 'research' / f'{NAME}_{suffix}').write_text(json.dumps(value, indent=2) + '\n')

def rows(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))

inputs = REF / 'frame_states.csv'
job = {'worker_pid': os.getpid(), 'started': time.time(), 'frames': 3301,
       'source_parent': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
       'runner_sha256': digest(Path(__file__)), 'input_sha256': digest(inputs),
       'scope': 'Actual CPU/legal recorded combat ports; extra accepted HUD write/RAM observations only'}
env = os.environ.copy()
env['ALPHA_BUILD_TMP'] = '/mnt/d/vibes/fpga/temp'
with (OUT / 'build.log').open('w') as log:
    command = ['bash', 'sim/build_system.sh']
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    job.update(build_pid=process.pid, build_command=command)
    save('job.json', job)
    code = process.wait()
    save('build_exit.json', {'exit_code': code, 'ended': time.time()})
    if code:
        raise SystemExit(code)
binary = OUT / 'alpha68kn_system_sim'
shutil.copyfile(ROOT / 'sim/build/alpha68kn_system_sim', binary)
binary.chmod(0o755)
shutil.copyfile(ROOT / 'sim/build/system_inputs.sha256', ROOT / 'research' / f'{NAME}_inputs.sha256')
job['runtime_rom_sha256'] = {}
for name in ['microrom.mem', 'nanorom.mem']:
    source, target = ROOT / 'rtl/vendor/fx68k' / name, OUT / name
    shutil.copyfile(source, target)
    assert digest(source) == digest(target)
    job['runtime_rom_sha256'][name] = digest(source)
command = [str(binary), str(ROOT / 'roms/kyros/download.bin'), '3301', str(OUT),
           'gameplay', '--inputs', str(inputs)]
with (OUT / 'run.log').open('w') as log:
    process = subprocess.Popen(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT)
    job.update(simulation_pid=process.pid, run_started=time.time(), command=command, executable_sha256=digest(binary))
    save('job.json', job)
    code = process.wait()
    job.update(exit_code=code, ended=time.time())
    save('exit.json', job)
if code:
    raise SystemExit(code)

# Preserve the previous actual game behavior. New diagnostic rows/assets do
# not turn existing MAME atomic-image mismatches into acceptance passes.
checks = {}
frames = rows(OUT / 'frames.csv')
last_tick = int(rows(OUT / 'snapshot_state.csv')[-1]['tick'])
checks['all_3301_actual_fields'] = len(frames) == 3301 and all(int(r['pixels']) == 57344 and all(int(r[k]) == 0 for k in ['duplicates', 'unmapped', 'deadline_misses', 'row_overflows']) for r in frames)
checks['frames.csv'] = frames == rows(BASE / 'frames.csv')[:3301]
checks['bus.csv'] = digest(OUT / 'bus.csv') == digest(BASE / 'bus.csv')
checks['audio_events.csv'] = rows(OUT / 'audio_events.csv') == [r for r in rows(BASE / 'audio_events.csv') if int(r['tick']) <= last_tick]
actual_inputs = rows(OUT / 'applied_inputs.csv')
checks['applied_inputs.csv'] = actual_inputs == rows(BASE / 'applied_inputs.csv')[:len(actual_inputs)]
for path in sorted(BASE.glob('frame_*.rgb')):
    field = int(path.stem.split('_')[1])
    if field < 3301:
        checks[path.name] = digest(OUT / path.name) == digest(path)
with wave.open(str(OUT / 'audio.wav'), 'rb') as a, wave.open(str(BASE / 'audio.wav'), 'rb') as b:
    checks['audio_format'] = (a.getnchannels(), a.getsampwidth(), a.getframerate()) == (b.getnchannels(), b.getsampwidth(), b.getframerate())
    checks['audio_pcm_prefix'] = a.readframes(a.getnframes()) == b.readframes(a.getnframes())
checks['all_hud_targets_have_ram'] = all((OUT / f'frame_{f:06d}.{suffix}').exists() for f in [900, 1020, 2100, 2220, 3180, 3300] for suffix in ['rgb', 'sprites.bin', 'work.bin'])
checks['previously_missing_targets_captured'] = all((OUT / f'frame_{f:06d}.rgb').exists() for f in [119, 179, 1799])
result = {'passed': all(checks.values()), 'checks': checks, 'last_tick': last_tick,
          'executable_sha256': job['executable_sha256'], 'source_parent': job['source_parent'],
          'simulation_wall_seconds': job['ended'] - job['run_started'],
          'scope': 'Actual 3301-field trace and native-baseline behavior preservation. MAME HUD temporal causality requires separate analysis; no graphics acceptance waiver.'}
save('verification.json', result)
print(json.dumps({'passed': result['passed'], 'failures': [n for n, v in checks.items() if not v], 'seconds': result['simulation_wall_seconds']}))
raise SystemExit(0 if result['passed'] else 1)
