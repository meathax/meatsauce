"""Qualify real five-field profiling captures against the native CPU baseline."""
from pathlib import Path
import csv, hashlib, json, wave

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'sim/captures/rtl/kyros_instruction60_diagnostic'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def rows(path):
    with path.open(newline='') as stream:
        return list(csv.DictReader(stream))

def qualify(attempt):
    name = f'kyros_system_profile5_v{attempt}'
    capture = ROOT / 'sim/captures/diagnostics' / name
    receipt = json.loads((ROOT / 'research' / f'{name}_exit.json').read_text())
    checks = {'terminal_exit_zero': receipt['exit_code'] == 0}
    assets = {}
    for field in range(5):
        for suffix in ['rgb', 'sprites.bin', 'work.bin']:
            filename = f'frame_{field:06d}.{suffix}'
            assets[filename] = digest(capture / filename)
            checks[filename] = assets[filename] == digest(BASE / filename)
    state = rows(capture / 'snapshot_state.csv')
    last_tick = int(state[-1]['tick'])
    for filename in ['frames.csv', 'snapshot_state.csv']:
        checks[filename] = rows(capture / filename) == rows(BASE / filename)[:5]
    for filename in ['bus.csv', 'audio_events.csv', 'epoch_events.csv']:
        expected = [r for r in rows(BASE / filename) if int(r['tick']) <= last_tick]
        checks[filename] = rows(capture / filename) == expected
    inputs = rows(capture / 'applied_inputs.csv')
    checks['applied_inputs.csv'] = inputs == rows(BASE / 'applied_inputs.csv')[:len(inputs)]
    with wave.open(str(capture / 'audio.wav'), 'rb') as a, wave.open(str(BASE / 'audio.wav'), 'rb') as b:
        checks['audio_format'] = (a.getnchannels(), a.getsampwidth(), a.getframerate()) == (b.getnchannels(), b.getsampwidth(), b.getframerate())
        checks['audio_pcm_prefix'] = a.readframes(a.getnframes()) == b.readframes(a.getnframes())
    runtime_assets = receipt['runtime_rom_sha256']
    checks['runtime_roms'] = all(digest(capture / n) == h == digest(ROOT / 'rtl/vendor/fx68k' / n) for n, h in runtime_assets.items())
    return {'attempt': attempt, 'checks': checks, 'passed': all(checks.values()),
            'asset_sha256': assets, 'last_tick': last_tick,
            'simulation_wall_seconds': receipt['ended'] - receipt['run_started'],
            'executable_sha256': receipt['executable_sha256'],
            'scope': 'Five actual CPU fields, full RGB/RAM, accepted bus/audio events, and PCM prefix. This is not later gameplay, physical timing, or general throughput qualification.'}

if __name__ == '__main__':
    reports = [qualify(4), qualify(5)]
    result = {'captures': reports, 'passed': all(r['passed'] for r in reports),
              'baseline': str(BASE.relative_to(ROOT)),
              'scope': 'Compiler-instrumented matched pair; single-run wall times are observations, not a statistically established speedup.'}
    output = ROOT / 'research/system_profile_pair_verification.json'
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'failures': {r['attempt']: [n for n, v in r['checks'].items() if not v] for r in reports}, 'seconds': [r['simulation_wall_seconds'] for r in reports], 'receipt': str(output)}))
    raise SystemExit(0 if result['passed'] else 1)
