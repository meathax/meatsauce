#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Capture exact MAME sound-event timestamps without changing canonical Lua."""
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def main():
    project = Path(__file__).resolve().parents[1]
    os.chdir(project)
    check = Path('_checks/sound-pin-precision-20261010')
    check.mkdir(exist_ok=False)
    output = Path('sim/results/current-sound-precision-1201-mame-20261010').resolve()
    output.mkdir(exist_ok=False)
    canonical = Path('sim/mame_capture.lua')
    source = canonical.read_text()
    header = 'time,frame,pc,p1,p2,dac\\n'
    fmt = "'%s,%d,%d,%d,%d,%d\\n',time(),frame,"
    tail = '(p2>>7)&1))'
    assert source.count(header) == source.count(fmt) == source.count(tail) == 1
    source = source.replace(header, 'time,frame,pc,p1,p2,dac,time_seconds,time_attoseconds\\n')
    source = source.replace(fmt, "'%s,%d,%d,%d,%d,%d,%d,%d\\n',time(),frame,")
    source = source.replace(tail, "(p2>>7)&1,value(value(machine,'time'),'seconds'),value(value(machine,'time'),'attoseconds')))")
    observer = check / 'observer.lua'
    observer.write_text(source, newline='\n')
    inputs = Path('_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv').resolve()
    mame = Path('D:/Arcade/AI/mameexe/mame.exe')
    env = os.environ.copy()
    env.update(SHERIFF_CAPTURE=output.as_posix(), SHERIFF_FRAMES='1201',
               SHERIFF_INPUTS=inputs.as_posix(), SHERIFF_SOUND_PROBE='1', SHERIFF_INPUT_POLICY='',
               SHERIFF_WRITE_PROBE_FRAME='-1', SHERIFF_INPUT_PROBE_FRAME='-1',
               SHERIFF_IRQ_PROBE='0', SHERIFF_PIXEL_PROBE='0')
    argv = [str(mame), 'sheriff', '-rompath', 'D:/Arcade/AI/MAME 0.289 ROMs (merged)',
            '-video', 'none', '-sound', 'none', '-nothrottle', '-nosleep', '-skip_gameinfo',
            '-noplugins', '-autoboot_delay', '0', '-autoboot_script', str(observer.resolve()),
            '-wavwrite', str(output/'audio.wav'), '-cfg_directory', str(output/'cfg'),
            '-nvram_directory', str(output/'nvram')]
    features = dict(sound_probe=True, exact_attotime=True, lua_sha256=sha(observer),
                    canonical_lua_sha256=sha(canonical), producer_sha256=sha(__file__),
                    mame_binary_sha256=sha(mame), input_sha256=sha(inputs))
    write(output/'capture_features.json', features)
    write(output/'input_sha256.json', dict(Hash=sha(inputs)))
    started = datetime.now(timezone.utc).isoformat()
    with (output/'stdout.log').open('wb') as stdout, (output/'stderr.log').open('wb') as stderr:
        process = subprocess.Popen(argv, cwd=project, env=env, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        write(output/'launch.json', dict(pid=process.pid, started_utc=started, argv=argv))
        code = process.wait(timeout=180)
    receipt = dict(exit_code=code, started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(),
                   process_id=process.pid, frames_requested=1201, features=features)
    write(output/'exit.json', receipt)
    assert code == 0
    frozen = Path('sim/results/current-sound-pins-1201-mame-20261010')
    same = {name: sha(output/name) == sha(frozen/name) for name in ('io.csv','audio.wav','states.csv')}
    assert all(same.values()), 'Precision observer changed reference behavior'
    old_rows = list(csv.DictReader((frozen/'sound_pins.csv').open()))
    new_rows = list(csv.DictReader((output/'sound_pins.csv').open()))
    assert len(old_rows) == len(new_rows)
    assert all(all(a[k] == b[k] for k in a) for a, b in zip(old_rows,new_rows))
    assert sha(canonical) == features['canonical_lua_sha256']
    result = dict(receipt=receipt, observer_unchanged=same, sound_rows=len(new_rows),
                  original_sound_columns_unchanged=True, canonical_lua_unchanged=True,
                  evidence_sha256={p.as_posix():sha(p) for p in
                      [observer,output/'exit.json',output/'sound_pins.csv',output/'capture_features.json']},
                  game_state_forced=False, release_qualified=False, rbf_built=False)
    write(check/'terminal.json', result)
    print(json.dumps(dict(actual_exit_code=code, sound_rows=len(new_rows), unchanged=same,
                          exact_attotime=True, evidence=(check/'terminal.json').as_posix())))


if __name__ == '__main__':
    main()
