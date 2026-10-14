"""Add read-only exact-time observers to the existing legal MAME combat run."""
from pathlib import Path
import csv, hashlib, itertools, json, os, subprocess, time
from normalize_oracle_display import normalize

ROOT = Path(__file__).resolve().parents[1]
NAME = 'kyros_combat3600_clocked'
OUT = ROOT / 'sim/captures/kyros/combat3600_clocked'
BASE = ROOT / 'sim/captures/kyros/combat3600_v2'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(suffix, value):
    (ROOT / 'research' / f'{NAME}_{suffix}').write_text(json.dumps(value, indent=2) + '\n')

def derive():
    source = ROOT / 'sim/mame/capture_combat.lua'
    body = source.read_text()
    replacements = [
        ('local scan = beam()', 'local scan, horizontal = beam()'),
        ('events:write("frame,screen_frame,area,address,data,mask,vpos\\n")',
         'events:write("frame,screen_frame,area,address,data,mask,vpos,hpos,master_ticks\\n")'),
        ('events:write(string.format("%d,%d,%s,%d,%d,%d,%d\\n",',
         'events:write(string.format("%d,%d,%s,%d,%d,%d,%d,%d,%d\\n",'),
        ('frame, screen:frame_number(), area, address, data, mask, scan))',
         'frame, screen:frame_number(), area, address, data, mask, scan, horizontal, machine.time:as_ticks(48000000)))'),
        ('local function capture_frame()\n',
         'local clock_trace = open("raster_clock.csv")\nclock_trace:write("frame,master_ticks,vpos,hpos\\n")\nlocal function capture_frame()\n    local capture_y, capture_x = beam()\n    clock_trace:write(string.format("%d,%d,%d,%d\\n", frame, machine.time:as_ticks(48000000), capture_y, capture_x))\n    clock_trace:flush()\n')]
    for before, after in replacements:
        if body.count(before) != 1:
            raise SystemExit('Refuse ambiguous original MAME observer replacement')
        body = body.replace(before, after)
    script = ROOT / 'sim/mame/capture_combat_clocked.lua'
    script.write_text(body)
    return source, script

if __name__ == '__main__':
    if os.name != 'nt':
        raise SystemExit('Use native Windows Python for the Windows MAME executable')
    if OUT.exists() or (ROOT / 'research' / f'{NAME}_job.json').exists():
        raise SystemExit('Refuse existing capture or job overwrite')
    source, script = derive()
    OUT.mkdir(parents=True)
    template = json.loads((ROOT / 'research/kyros_combat3600_v2_job.json').read_text())
    command = list(template['command'])
    command[command.index('-autoboot_script') + 1] = str(script)
    for flag, target in [('-snapshot_directory', OUT), ('-cfg_directory', OUT / 'cfg'),
                         ('-nvram_directory', OUT / 'nvram'), ('-state_directory', OUT / 'states'),
                         ('-wavwrite', OUT / 'audio.wav')]:
        command[command.index(flag) + 1] = str(target)
    env = {**os.environ, 'ALPHA_CAPTURE_DIR': str(OUT), 'ALPHA_CAPTURE_FRAMES': '3600', 'ALPHA_CAPTURE_MODE': 'combat'}
    job = {'worker_pid': os.getpid(), 'started': time.time(), 'command': command,
           'source_parent': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
           'base_source_sha256': digest(source), 'derived_source_sha256': digest(script),
           'mame_sha256': digest(Path(command[0])), 'frames': 3600,
           'scope': 'Identical real MAME combat CPUs/legal controls with additional beam/time observations; no state injection'}
    with (OUT / 'run.log').open('w') as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        job.update(mame_pid=process.pid)
        save('job.json', job)
        code = process.wait()
    job.update(exit_code=code, ended=time.time())
    save('exit.json', job)
    if code:
        raise SystemExit(code)
    normalize(OUT.resolve())
    checks = {'frame_states.csv': digest(OUT / 'frame_states.csv') == digest(BASE / 'frame_states.csv')}
    with (BASE / 'events.csv').open(newline='') as a, (OUT / 'events.csv').open(newline='') as b:
        expected, observed = csv.DictReader(a), csv.DictReader(b)
        event_count, event_failure = 0, None
        for index, (x, y) in enumerate(itertools.zip_longest(expected, observed)):
            if x is None or y is None or x != {k: y[k] for k in expected.fieldnames}:
                event_failure = index
                break
            event_count += 1
    checks['complete_original_event_projection'] = event_failure is None
    for path in sorted(BASE.glob('frame_*.display.rgb')):
        checks[path.name] = (OUT / path.name).exists() and digest(path) == digest(OUT / path.name)
    checks['audio.wav'] = digest(OUT / 'audio.wav') == digest(BASE / 'audio.wav')
    with (OUT / 'raster_clock.csv').open() as stream:
        clocks = list(csv.DictReader(stream))
    checks['all_3600_exact_clock_markers'] = len(clocks) == 3600 and all(int(r['frame']) == i for i, r in enumerate(clocks))
    result = {'passed': all(checks.values()), 'checks': checks, 'original_events_matched': event_count,
              'first_original_event_failure': event_failure, 'source_parent': job['source_parent'],
              'scope': 'Complete original MAME oracle equivalence with added integer 48MHz write/beam time. No native CPU/pixel acceptance claim.'}
    save('verification.json', result)
    print(json.dumps({'passed': result['passed'], 'failures': [k for k, v in checks.items() if not v], 'events': event_count}))
    raise SystemExit(0 if result['passed'] else 1)
