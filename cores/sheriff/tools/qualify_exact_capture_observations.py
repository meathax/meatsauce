"""Run four real Sheriff fields to qualify the optional exact observation ledger."""
import csv
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import subprocess
import wave


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    project = Path(__file__).resolve().parents[1]
    os.chdir(project)
    output = Path('_checks/exact-capture-observations-20261010').resolve()
    output.mkdir(exist_ok=False)
    lua = Path('sim/mame_capture.lua').resolve()
    inputs = Path('_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv').resolve()
    mame = Path('D:/Arcade/AI/mameexe/mame.exe')
    before = {p.as_posix(): sha(p) for p in [lua, inputs, mame, Path(__file__)]}
    env = os.environ.copy()
    env.update(SHERIFF_CAPTURE=output.as_posix(), SHERIFF_FRAMES='4',
               SHERIFF_INPUTS=inputs.as_posix(), SHERIFF_SOUND_PROBE='1',
               SHERIFF_EXACT_OBSERVATIONS='1', SHERIFF_INPUT_POLICY='',
               SHERIFF_WRITE_PROBE_FRAME='-1', SHERIFF_INPUT_PROBE_FRAME='-1',
               SHERIFF_IRQ_PROBE='0', SHERIFF_PIXEL_PROBE='0')
    argv = [str(mame), 'sheriff', '-rompath', 'D:/Arcade/AI/MAME 0.289 ROMs (merged)',
            '-video', 'none', '-sound', 'none', '-nothrottle', '-nosleep', '-skip_gameinfo',
            '-noplugins', '-autoboot_delay', '0', '-autoboot_script', str(lua),
            '-wavwrite', str(output / 'audio.wav'), '-cfg_directory', str(output / 'cfg'),
            '-nvram_directory', str(output / 'nvram')]
    started = datetime.now(timezone.utc).isoformat()
    with (output / 'stdout.log').open('wb') as out, (output / 'stderr.log').open('wb') as err:
        process = subprocess.Popen(argv, cwd=project, env=env, stdout=out, stderr=err,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        (output / 'launch.json').write_text(json.dumps(dict(pid=process.pid, argv=argv,
                                                         started_utc=started), indent=2))
        code = process.wait(timeout=45)
    receipt = dict(exit_code=code, pid=process.pid, started_utc=started,
                   finished_utc=datetime.now(timezone.utc).isoformat(), frames_requested=4)
    (output / 'exit.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert code == 0, receipt
    assert 'error' not in (output / 'stdout.log').read_text().lower()
    assert 'error' not in (output / 'stderr.log').read_text().lower()
    assert all(sha(p) == h for p, h in before.items())
    frozen = Path('sim/results/restart-mame')
    equal = {}
    for frame in range(1, 5):
        for ext in ('ram', 'idx32'):
            name = f'frame_{frame:05d}.{ext}'
            equal[name] = sha(output / name) == sha(frozen / name)
    for name in ('io.csv', 'states.csv', 'video_writes.csv'):
        b = (output / name).read_bytes()
        with (frozen / name).open('rb') as f:
            equal[name + '_prefix'] = f.read(len(b)) == b
    with wave.open(str(output / 'audio.wav')) as current, wave.open(str(frozen / 'audio.wav')) as old:
        assert current.getnchannels() == old.getnchannels() == 1
        assert current.getsampwidth() == old.getsampwidth() == 2
        assert current.getframerate() == old.getframerate() == 48000
        samples = current.getnframes()
        equal['audio_PCM_prefix'] = current.readframes(samples) == old.readframes(samples)
    assert all(equal.values()), equal
    with (output / 'observations_exact.csv').open(newline='') as stream:
        rows = list(csv.DictReader(stream))
    assert [int(r['sequence']) for r in rows] == list(range(1, len(rows)+1))
    assert all(0 <= int(r['time_attoseconds']) < 10**18 for r in rows)
    exact = [int(r['time_seconds']) * 10**18 + int(r['time_attoseconds']) for r in rows]
    reversals = [dict(sequence=int(rows[i]['sequence']), previous_kind=rows[i-1]['kind'],
                      kind=rows[i]['kind'], previous_attoseconds=str(exact[i-1]),
                      attoseconds=str(exact[i])) for i in range(1, len(rows)) if exact[i] < exact[i-1]]
    kinds = {k: sum(r['kind'] == k for r in rows) for k in sorted({r['kind'] for r in rows})}
    assert kinds['frame_begin'] == kinds['frame_end'] == kinds['ram_snapshot'] == 4
    with (output / 'video_writes.csv').open(newline='') as stream:
        writes = list(csv.DictReader(stream))
    observed_writes = [r for r in rows if r['kind'] == 'ram_write']
    assert len(writes) == len(observed_writes)
    for old, new in zip(writes, observed_writes):
        assert all(old[k] == new[k] for k in ('frame', 'address', 'data'))
        t = Decimal(new['time_seconds']) + Decimal(new['time_attoseconds']) / 10**18
        assert abs(t - Decimal(old['time'])) < Decimal('0.000000000000501')
    report = dict(scope='Four-field real MAME 0.289 Sheriff instrumentation test, not a gameplay/raster release pass.',
                  receipt=receipt, source_sha256=before, unchanged_reference_payloads=equal,
                  exact_events=len(rows), event_kinds=kinds, PCM_samples=samples,
                  timestamp_reversals=reversals,
                  evidence_sha256={p.as_posix(): sha(p) for p in output.iterdir() if p.is_file()},
                  integer_time_fields=True, common_callback_sequence=True,
                  graphics_gate_pass=False, complete_gameplay_gate_pass=False,
                  limits=['Exact machine time retains CPU-local versus frame-callback context; it is not a physical bus timestamp.',
                          'No saved long capture was changed or rerun; full lifecycle and mixed sound capture precision remain scoped to their original receipts.'])
    target = Path('docs/evidence/sheriff_exact_capture_observations.json')
    target.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(actual_exit_code=code, events=len(rows), event_kinds=kinds,
                          unchanged=all(equal.values()), timestamp_reversals=len(reversals),
                          evidence=target.as_posix())))


if __name__ == '__main__':
    main()
