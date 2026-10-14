"""Build and qualify the real native CPU through the retained field-60 IRQ case."""
from pathlib import Path
import csv, hashlib, json, os, shutil, subprocess, time, sys

ROOT = Path(__file__).resolve().parents[1]
NAME = 'kyros_system_equivalence61'
OUT = ROOT / 'sim/captures/rtl' / NAME
BASE = ROOT / 'sim/captures/rtl/kyros_instruction60_diagnostic'
if os.name != 'posix' or not str(ROOT).startswith('/mnt/d/'):
    raise SystemExit('Run explicitly through Ubuntu WSL')
if OUT.exists() or (ROOT / 'research' / f'{NAME}_job.json').exists():
    raise SystemExit('Refusing to overwrite an existing capture or job')
OUT.mkdir(parents=True)
job = {'worker_pid': os.getpid(), 'started': time.time(), 'frames': 61,
       'source_parent': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
       'scope': 'Real native CPU equivalence through backdrop field60; no clock/game RTL changes'}

def save(suffix, data):
    (ROOT / 'research' / f'{NAME}_{suffix}').write_text(json.dumps(data, indent=2) + '\n')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

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
    source = ROOT / 'rtl/vendor/fx68k' / name
    target = OUT / name
    shutil.copyfile(source, target)
    assert digest(source) == digest(target)
    job['runtime_rom_sha256'][name] = digest(source)
command = [str(binary), str(ROOT / 'roms/kyros/download.bin'), '61', str(OUT),
           'gameplay', '--inputs', str(ROOT / 'sim/captures/kyros/warm_reset960_refv2/frame_states.csv')]
with (OUT / 'run.log').open('w') as log:
    process = subprocess.Popen(command, cwd=OUT, stdout=log, stderr=subprocess.STDOUT)
    job.update(simulation_pid=process.pid, run_started=time.time(), command=command, executable_sha256=digest(binary))
    save('job.json', job)
    code = process.wait()
    job.update(exit_code=code, ended=time.time())
    save('exit.json', job)
if code:
    raise SystemExit(code)

checks = {}
assets = {}
for path in sorted(BASE.glob('frame_*')):
    target = OUT / path.name
    checks[path.name] = target.exists() and digest(target) == digest(path)
    if target.exists():
        assets[path.name] = digest(target)
for name in ['frames.csv', 'snapshot_state.csv', 'bus.csv', 'audio_events.csv',
             'epoch_events.csv', 'instruction_events.csv', 'applied_inputs.csv',
             'audio.wav', 'audio.json', 'sprites.bin', 'work.bin']:
    checks[name] = digest(OUT / name) == digest(BASE / name)
checks['runtime_roms'] = all(digest(OUT / n) == h == digest(ROOT / 'rtl/vendor/fx68k' / n) for n, h in job['runtime_rom_sha256'].items())
with (OUT / 'frames.csv').open() as stream:
    frames = list(csv.DictReader(stream))
checks['all_61_actual_fields'] = len(frames) == 61 and all(int(r['pixels']) == 57344 and all(int(r[k]) == 0 for k in ['duplicates', 'unmapped', 'deadline_misses', 'row_overflows']) for r in frames)
result = {'passed': all(checks.values()), 'checks': checks, 'asset_sha256': assets,
          'executable_sha256': job['executable_sha256'], 'source_parent': job['source_parent'],
          'simulation_wall_seconds': job['ended'] - job['run_started'],
          'baseline': str(BASE.relative_to(ROOT)),
          'scope': 'Real 61-field CPU equivalence, including retained field59 IRQ context and field60 raster backdrop. This preserves previous MAME differences; it does not fix or waive them.'}
save('verification.json', result)
print(json.dumps({'passed': result['passed'], 'failures': [n for n, v in checks.items() if not v], 'seconds': result['simulation_wall_seconds']}))
raise SystemExit(0 if result['passed'] else 1)
