"""Test measured pre-update HUD words with the actual strip/SDRAM renderer."""
from pathlib import Path
import csv, hashlib, json, os, shutil, subprocess, time

ROOT = Path(__file__).resolve().parents[1]
NAME = 'combat_hud_prewrite_fixtures'
OUT = ROOT / 'sim/captures/diagnostics' / NAME
REF = ROOT / 'sim/captures/kyros/combat3600_clocked'
NATIVE = ROOT / 'sim/captures/rtl/kyros_combat3600'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(suffix, value):
    (ROOT / 'research' / f'{NAME}_{suffix}').write_text(json.dumps(value, indent=2) + '\n')

if __name__ == '__main__':
    if os.name != 'posix' or not str(ROOT).startswith('/mnt/d/'):
        raise SystemExit('Run explicitly through Ubuntu WSL')
    if OUT.exists() or (ROOT / 'research' / f'{NAME}_job.json').exists():
        raise SystemExit('Refuse capture/job overwrite')
    timing_path = ROOT / 'research/combat_hud_mame_timing_v2.json'
    timing = json.loads(timing_path.read_text())
    if not timing['passed']:
        raise SystemExit('MAME write timeline must reconstruct all target final RAM')
    with (REF / 'frame_states.csv').open() as stream:
        states = list(csv.DictReader(stream))
    OUT.mkdir(parents=True)
    job = {'worker_pid': os.getpid(), 'started': time.time(), 'source_parent': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
           'runner_sha256': digest(Path(__file__)), 'timing_sha256': digest(timing_path),
           'scope': 'Actual renderer diagnostic with MAME-measured earlier HUD words; no CPU/gameplay bring-up substitute'}
    env = os.environ.copy()
    env['ALPHA_BUILD_TMP'] = '/mnt/d/vibes/fpga/temp'
    with (OUT / 'build.log').open('w') as log:
        command = ['bash', 'sim/build_renderer.sh']
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        job.update(build_pid=process.pid, build_command=command)
        save('job.json', job)
        code = process.wait()
        save('build_exit.json', {'exit_code': code, 'ended': time.time()})
        if code:
            raise SystemExit(code)
    binary = OUT / 'alpha68kn_render_fixture_sim'
    shutil.copyfile(ROOT / 'sim/build/alpha68kn_render_fixture_sim', binary)
    binary.chmod(0o755)
    shutil.copyfile(ROOT / 'sim/build/renderer_inputs.sha256', ROOT / 'research' / f'{NAME}_inputs.sha256')
    job['executable_sha256'] = digest(binary)
    save('job.json', job)
    results = []
    for case in timing['cases']:
        field = case['field']
        target = OUT / f'field_{field:06d}'
        target.mkdir()
        source_ram = REF / f'frame_{field:06d}.sprites.bin'
        ram = bytearray(source_ram.read_bytes())
        modifications = []
        for word in case['words']:
            if word['address'] == 0x406C2:
                if word['changed_writes']:
                    raise SystemExit('Position changed: static prewrite fixture cannot establish this case')
                continue
            changes = word['changed_writes']
            if not changes or int(changes[0]['known_before']) != 65535:
                raise SystemExit('Pre-update word is not fully known from accepted MAME writes')
            if any(int(r['vpos']) <= max(word['affected_raw_y']) for r in changes):
                raise SystemExit('HUD write not strictly after affected raster rows')
            earlier = int(changes[0]['before'])
            offset = word['address'] - 0x40000
            ram[offset:offset+2] = earlier.to_bytes(2, 'big')
            modifications.append({'address': word['address'], 'final': word['final_word'], 'earlier': earlier, 'changes': changes})
        fixture = target / 'sprites_prewrite.bin'
        fixture.write_bytes(ram)
        oracle = NATIVE / f'frame_{field:06d}.rgb'
        command = [str(binary), str(ROOT / 'roms/kyros/download.bin'), str(fixture),
                   str(int(states[field]['background']) & 255), str(target), '0', str(oracle)]
        run_started = time.time()
        process = subprocess.run(command, cwd=OUT, capture_output=True, text=True)
        (target / 'run.log').write_text(process.stdout + process.stderr)
        summary = next((json.loads(line) for line in reversed(process.stdout.splitlines()) if line.startswith('{')), None)
        actual = target / 'actual.rgb'
        pixel_equal = actual.exists() and actual.read_bytes() == oracle.read_bytes()
        results.append({'field': field, 'exit_code': process.returncode, 'summary': summary,
                        'actual_matches_all_native_rgb': pixel_equal, 'modifications': modifications,
                        'source_ram_sha256': digest(source_ram), 'fixture_sha256': digest(fixture),
                        'oracle_sha256': digest(oracle), 'actual_sha256': digest(actual) if actual.exists() else None,
                        'command': command, 'wall_seconds': time.time() - run_started})
        save('partial_results.json', results)
    passed = all(r['exit_code'] == 0 and r['actual_matches_all_native_rgb'] for r in results)
    result = {'passed': passed, 'results': results, 'executable_sha256': job['executable_sha256'],
              'scope': 'Six complete 57344-pixel actual renderer fixture comparisons against actual CPU images using independently measured MAME pre-update HUD words. Full native accepted-write causality remains pending; original atomic differences are retained.'}
    save('verification.json', result)
    job.update(exit_code=0 if passed else 1, ended=time.time())
    save('exit.json', job)
    print(json.dumps({'passed': passed, 'fields': [(r['field'], r['exit_code'], r['actual_matches_all_native_rgb']) for r in results]}))
    raise SystemExit(0 if passed else 1)
