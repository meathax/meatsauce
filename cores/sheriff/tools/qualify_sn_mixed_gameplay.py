#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Reuse the native dual-SN model on the first real mono0/overlap prefix."""
import array
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def main():
    check = Path('_checks/sn-mixed-gameplay-20261010')
    check.mkdir(exist_ok=False)
    coverage_path = Path('docs/evidence/sheriff_sound_control_coverage.json')
    coverage = json.loads(coverage_path.read_text())['captures'][1]
    original_path = Path('docs/evidence/sheriff_current_cocktail.json')
    original = json.loads(original_path.read_text())['native_receipt']
    assert original['exit_code'] == 0 and not original['source_changed_during_run']
    for path in ['rtl/n8080_board.sv', 'rtl/n8080_mcs48.sv', 'rtl/sheriff_sn76477.sv']:
        assert sha(path) == original['source_sha256'][path], path
    old = Path('_checks/sn-gameplay-replay-20261010/old_sn_constants.svh')
    assert sha(old) == original['source_sha256']['rtl/sheriff_sn_constants.svh']
    binary = Path('_checks/sn-gameplay-replay-20261010/build/Vsn_gameplay_replay')
    replay_path = Path('docs/evidence/sheriff_sn_gameplay_replay.json')
    replay = json.loads(replay_path.read_text())
    binding = replay['completed_case_source_binding']['evidence_sha256']
    assert sha(binary) == binding[binary.as_posix()]
    for path, digest in replay['completed_case_source_binding']['source_sha256'].items():
        assert sha(path) == digest, path
    native = Path(original['runtime_output'])
    io = native/'io.csv'
    assert sha(io) == coverage['sha256']
    target = coverage['first_occurrences']['mono1_overlaps_mono0']['row']
    end_tick = int(target['tick']) + 1 + 30187080
    count = (end_tick + 1049)//1050 + 64
    raw = array.array('h')
    with (native/'audio.raw').open('rb') as stream:
        raw.frombytes(stream.read(count*2))
    assert len(raw) == count
    old_sn = array.array('h')
    with (native/'sound.csv').open(newline='') as stream:
        pins = csv.DictReader(stream)
        next_pin = next(pins, None)
        dac = 1
        for sample, value in enumerate(raw):
            tick = 1049 + 1050*sample
            while next_pin and int(next_pin['tick']) <= tick:
                dac = int(next_pin['dac'])
                next_pin = next(pins, None)
            old_sn.append(value - (4915 if dac else 0))
    expected = check/'old-expected-sn.raw'
    expected.write_bytes(old_sn.tobytes())
    sources = [Path(__file__), coverage_path, original_path, replay_path,
               io, native/'sound.csv', native/'audio.raw', old, binary, expected,
               Path('rtl/n8080_board.sv'), Path('rtl/n8080_mcs48.sv'),
               Path('rtl/sheriff_sn76477.sv'), Path('rtl/sheriff_sn_constants.svh'),
               Path('sim/sn_gameplay_replay.cpp'), Path('tools/run_native_with_receipt.sh')]
    before = {p.as_posix(): sha(p) for p in sources}
    linux = '/mnt/d/Arcade/AI/aCORES/sherrif/'
    argv = ['wsl.exe', '-d', 'Ubuntu', '--cd', str(Path.cwd()), '--exec',
            '/bin/bash', linux+'tools/run_native_with_receipt.sh',
            linux+check.as_posix()+'/native-exit-code.txt',
            linux+binary.as_posix(), linux+io.as_posix(),
            linux+expected.as_posix(), linux+check.as_posix()+'/run']
    started = datetime.now(timezone.utc).isoformat()
    with (check/'stdout.log').open('wb') as out, (check/'stderr.log').open('wb') as err:
        process = subprocess.Popen(argv, stdout=out, stderr=err)
        write(check/'launch.json', {'pid': process.pid, 'argv': argv,
                                   'started_utc': started, 'samples': count,
                                   'source_sha256': before})
        print(json.dumps({'pid': process.pid, 'samples': count, 'handle': str(check/'launch.json')}), flush=True)
        code = process.wait()
    changed = [p for p, digest in before.items() if sha(p) != digest]
    native_exit = int((check/'native-exit-code.txt').read_text())
    terminal = {'exit_code': code, 'native_exit_code': native_exit, 'started_utc': started,
                'finished_utc': datetime.now(timezone.utc).isoformat(),
                'source_changed_during_run': changed}
    write(check/'terminal.json', terminal)
    assert code == native_exit == 0 and not changed, terminal
    result_path = check/'run/native-result.json'
    result = json.loads(result_path.read_text())
    assert result['samples'] == count and result['old_identity_differences'] == 0
    output_sources = [check/'launch.json', check/'terminal.json', check/'native-exit-code.txt', check/'stdout.log',
                      check/'stderr.log', result_path, check/'run/old-sn.raw',
                      check/'run/current-sn.raw', check/'run/capacitor_window.csv']
    report = {
        'scope': 'Native chip replay of actual cocktail 8080 writes through the first mono0 cancellation and mono1 overlap expiry; not CPU/full-board/current-gameplay or MAME waveform qualification.',
        'terminal': terminal, 'native': result,
        'target_first_mono0': coverage['first_occurrences']['mono0_triggers'],
        'target_first_overlap': coverage['first_occurrences']['mono1_overlaps_mono0'],
        'source_sha256': before,
        'evidence_sha256': {p.as_posix(): sha(p) for p in output_sources},
        'existing_native_model_reused': True, 'full_gameplay_rerun': False,
        'whole_audio_gate_pass': False, 'mame_mixed_class_waveform_pass': False,
        'limits': ['The original native board audio is the old-gain identity oracle; zero identity differences validate replay routing and state, not MAME equivalence.',
                   'Mono1 retriggers in the separate MAME recording remain to be qualified.',
                   'Physical raster, first graphics divergence, final-source fit/STA/resources and complete gameplay gates remain open.'],
    }
    output = Path('docs/evidence/sheriff_sn_mixed_gameplay.json')
    write(output, report)
    print(json.dumps({'report': output.as_posix(), 'terminal': terminal, 'native': result}), flush=True)


if __name__ == '__main__':
    main()
