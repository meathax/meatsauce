# SPDX-License-Identifier: GPL-2.0-or-later
"""Required short boundary diagnostic, using the retained native model and ROM."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def main():
    project = Path(__file__).resolve().parents[1]
    os.chdir(project)
    root = Path('_checks/first-irq66-boundary-20261010')
    root.mkdir(exist_ok=False)
    native, mame = root/'native', root/'mame'
    native.mkdir(); mame.mkdir()
    model = Path('_checks/current-board-boot-20261010/Vn8080_board')
    assert sha(model) == '6b98d5757c16f6958f1dfea5d40c1254b6f5ebfe9f456b961e3b2f12a6e41d09'
    model_receipt = Path('_checks/current-board-boot-20261010/terminal.json')
    binding = json.loads(model_receipt.read_text(encoding='utf-8-sig'))
    main_sources = ['rtl/n8080_board.sv', 'rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v', 'sim/board_harness.cpp']
    assert all(sha(p) == binding['source_sha256'][p] for p in main_sources)
    inputs = Path('_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv')
    rom = Path('roms/sheriff.bin')
    observer = Path('sim/mame_capture.lua')
    mame_exe = Path('D:/Arcade/AI/mameexe/mame.exe')
    files = [Path(__file__), model, model_receipt, inputs, rom, observer,
             Path('tools/run_native_with_receipt.sh'), mame_exe, *map(Path, main_sources)]
    hashes = {p.as_posix(): sha(p) for p in files}
    context = dict(source_sha256=hashes, native_model_binding=binding,
                   scope='Main CPU/raster IRQ boundary diagnostic; retained model uses pre-conversion SN constants and does not qualify current integrated audio.',
                   first_irq_difference='docs/evidence/sheriff_first_irq_return_difference.json')
    save(root/'source-binding.json', context)
    env = os.environ.copy()
    env.update(SHERIFF_CAPTURE=mame.resolve().as_posix(), SHERIFF_FRAMES='68',
               SHERIFF_INPUTS=inputs.resolve().as_posix(), SHERIFF_SOUND_PROBE='1',
               SHERIFF_EXACT_OBSERVATIONS='1', SHERIFF_INPUT_POLICY='',
               SHERIFF_WRITE_PROBE_FRAME='-1', SHERIFF_INPUT_PROBE_FRAME='-1',
               SHERIFF_IRQ_PROBE='1', SHERIFF_IRQ_FRAME='65', SHERIFF_PIXEL_PROBE='0')
    commands = dict(
        mame=[str(mame_exe), 'sheriff', '-rompath', 'D:/Arcade/AI/MAME 0.289 ROMs (merged)',
              '-video', 'none', '-sound', 'none', '-nothrottle', '-nosleep', '-skip_gameinfo',
              '-noplugins', '-autoboot_delay', '0', '-autoboot_script', str(observer.resolve()),
              '-wavwrite', str((mame/'audio.wav').resolve()),
              '-cfg_directory', str((mame/'cfg').resolve()),
              '-nvram_directory', str((mame/'nvram').resolve())],
        native=['C:/Windows/System32/wsl.exe', '-d', 'Ubuntu', '--cd', str(project), '--exec',
                '/bin/bash', 'tools/run_native_with_receipt.sh',
                (root/'native-exit-code.txt').as_posix(), '/usr/bin/env', 'SHERIFF_BUS_FRAMES=64,65,66',
                model.as_posix(), rom.as_posix(), native.as_posix(), '68', inputs.as_posix(),
                '+verilator+seed+1'])
    handles, processes = {}, {}
    started = datetime.now(timezone.utc).isoformat()
    for kind, argv in commands.items():
        handles[kind] = [(root/(kind+'-stdout.log')).open('wb'), (root/(kind+'-stderr.log')).open('wb')]
        processes[kind] = subprocess.Popen(argv, cwd=project, env=env,
                                           stdout=handles[kind][0], stderr=handles[kind][1],
                                           creationflags=subprocess.CREATE_NO_WINDOW)
    save(root/'launch.json', dict(started_utc=started, host_pid=os.getpid(),
                                 child_pids={k:p.pid for k,p in processes.items()}, commands=commands))
    while any(p.poll() is None for p in processes.values()):
        time.sleep(1)
    exits = {k:p.returncode for k,p in processes.items()}
    for pair in handles.values():
        for f in pair: f.close()
    native_exit = root/'native-exit-code.txt'
    receipt = dict(started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(),
                   child_exit_codes=exits, native_OS_exit=int(native_exit.read_text()) if native_exit.exists() else None,
                   unchanged_sources=all(sha(p)==h for p,h in hashes.items()), frames_requested=68)
    save(root/'terminal.json', receipt)
    assert exits == dict(mame=0,native=0) and receipt['native_OS_exit']==0, receipt
    assert receipt['unchanged_sources']
    old_native = Path('sim/results/physical-cpu-restart-corners-rtl-20261009')
    old_mame = Path('sim/results/restart-mame')
    equal = {}
    for target, frozen, names in [(native, old_native, ['io.csv','memory_writes.bin','sound.csv','audio.raw']),
                                   (mame, old_mame, ['io.csv','video_writes.csv','states.csv'])]:
        for name in names:
            b = (target/name).read_bytes()
            with (frozen/name).open('rb') as f:
                equal[target.name+'/'+name] = f.read(len(b)) == b
    # Both captures add the requested terminal field68; its state row has no old counterpart.
    equal.pop('mame/states.csv')
    for target, frozen, extensions in [(native, old_native, ['ram','ppm']), (mame, old_mame, ['ram','idx32'])]:
        for frame in [1,2,3,4,60]:
            for ext in extensions:
                name=f'frame_{frame:05d}.{ext}'
                equal[target.name+'/'+name] = sha(target/name)==sha(frozen/name)
    save(root/'prefix-comparison.json', dict(equal=equal, all_equal=all(equal.values())))
    assert all(equal.values()), equal
    print(json.dumps(dict(root=root.as_posix(), actual_exits=exits,
                          native_OS_exit=receipt['native_OS_exit'], prefixes_identical=True)))


if __name__=='__main__':
    main()
