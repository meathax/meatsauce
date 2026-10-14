# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the current real board and qualify only the SN gain integration delta.

Windows host, explicit Ubuntu WSL. This is a saved same-side regression,
not all-domain live MAME lockstep or physical/audio/release acceptance.
"""
import array
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent.parent
ROOT = PROJECT/'_checks/current-gain-integration-20261010'
WORK = Path('D:/vibes/fpga/temp/sheriff-current-gain-integration-20261010')
SOURCES = ['rtl/n8080_board.sv', 'rtl/n8080_cpu.sv', 'rtl/n8080_vm80a_ce.v',
           'rtl/n8080_mcs48.sv', 'rtl/vendor/t48/t48_core.v',
           'rtl/sheriff_sn76477.sv', 'sim/board_harness.cpp',
           'rtl/sheriff_sn_constants.svh', 'tools/run_native_with_receipt.sh']
INPUTS = PROJECT/'_checks/physical-cpu-restart-corners-20261009/inputs_restart.csv'
FRAMES = 1201


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    temp = path.with_suffix(path.suffix+'.tmp')
    temp.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8', newline='')
    temp.replace(path)


def linux(path):
    path = path.resolve().as_posix()
    assert path[1:3] == ':/'
    return '/mnt/'+path[0].lower()+path[2:]


def samples(path):
    result = array.array('h')
    result.frombytes(path.read_bytes())
    if sys.byteorder != 'little':
        result.byteswap()
    return result


def compare(receipt):
    old_receipt_path = PROJECT/'_checks/current-gameplay-1201-20261010/terminal.json'
    old_receipt = json.loads(old_receipt_path.read_text(encoding='utf-8-sig'))
    assert old_receipt['exit_code'] == 0 and old_receipt['frames_requested'] == FRAMES
    assert not old_receipt['source_changed_during_run']
    old = PROJECT/old_receipt['runtime_output']
    native = ROOT/'native'
    for name in SOURCES[:7]:
        assert receipt['source_sha256'][name] == old_receipt['source_sha256'][name], name
    assert receipt['inputs_sha256'] == old_receipt['inputs_sha256']
    unchanged = {}
    for name in ['cpu_startup.csv', 'io.csv', 'memory_writes.bin', 'sound.csv']:
        unchanged[name] = sha(native/name) == sha(old/name)
        assert unchanged[name], name
    snapshots = sorted(p.name for p in native.iterdir() if p.suffix in ('.ppm', '.ram'))
    assert snapshots == sorted(p.name for p in old.iterdir() if p.suffix in ('.ppm', '.ram'))
    for name in snapshots:
        assert sha(native/name) == sha(old/name), name
    component = PROJECT/'_checks/sn-gameplay-replay-20261010/run-v3'
    component_report_path = PROJECT/'docs/evidence/sheriff_sn_gameplay_replay.json'
    component_report = json.loads(component_report_path.read_text())
    # Verify the archived data against the original qualified report; current
    # copies must match those archived bytes before using them as predictions.
    for name in ('old-sn.raw', 'current-sn.raw'):
        key = '_checks/sn-gameplay-replay-20261010/run/'+name
        assert sha(component/name) == component_report['evidence_sha256'][key]
    old_audio, new_audio = samples(old/'audio.raw'), samples(native/'audio.raw')
    old_sn, new_sn = samples(component/'old-sn.raw'), samples(component/'current-sn.raw')
    assert len(old_audio) == len(new_audio) == len(old_sn) == len(new_sn) == 937008
    changed = 0
    for i, (before, after, sn_before, sn_after) in enumerate(zip(old_audio, new_audio, old_sn, new_sn)):
        dac = before-sn_before
        assert dac in (0, 4915), (i, 'old board/component DAC decomposition', dac)
        expected = dac+sn_after
        assert -32768 <= expected <= 32767
        assert after == expected, (i, after, expected)
        changed += before != after
    assert changed == 25485
    paths = [old_receipt_path, component_report_path, old/'audio.raw',
             component/'old-sn.raw', component/'current-sn.raw', ROOT/'terminal.json']
    paths += sorted(p for p in native.iterdir() if p.is_file())
    report = dict(scope='Current synthesizable bare board, real parent ROM and MCU execution through1201 fields; same-side digital regression and exact gain-correction integration only.',
                  receipt=receipt, unchanged_digital_streams=unchanged,
                  identical_snapshots=snapshots, audio_samples=len(new_audio),
                  changed_audio_samples=changed, predicted_audio_mismatches=0,
                  evidence_sha256={str(p.relative_to(PROJECT)).replace('\\','/'):sha(p) for p in paths},
                  scoped_gain_integration_qualified=True, full_gameplay_gate_qualified=False,
                  full_audio_gate_qualified=False, full_graphics_gate_qualified=False,
                  physical_timing_qualified=False, release_qualified=False, rbf_built=False,
                  limits=['Stored same-side regression, not admitted live MAME lockstep.',
                          'Bare-board loader and selected snapshots; full MiSTer wrapper remains separate.',
                          'Only the first five mono1 bursts; mixed commands/cocktail/later lifecycle remain separate.',
                          'Q32 capacitor boundaries, hardware enable/retrigger decision and DAC recording contract remain open.',
                          'Field2760 graphics and exact-source queued fit/STA/resources remain open.'])
    write(PROJECT/'docs/evidence/sheriff_current_gain_integration.json', report)
    return dict(audio_samples=len(new_audio), changed_audio_samples=changed,
                predicted_audio_mismatches=0, snapshots=len(snapshots), digital_streams=unchanged)


def main():
    os.chdir(PROJECT)
    if ROOT.exists() or WORK.exists():
        raise RuntimeError('Existing run directory: inspect the original process/receipts; do not restart.')
    ROOT.mkdir(parents=True)
    hashes = {name:sha(PROJECT/name) for name in SOURCES}
    assert hashes['rtl/sheriff_sn_constants.svh'] == '8d36ae2502e3b69331bed1e5bd29af0c1cc660904dc0a8ba24e039ea2d46ec22'
    assert sha(INPUTS) == '15e27f7747d95c53762259b136b7b8aeff7e8a7c24dcf75ac81edad85456db3d'
    for name in SOURCES:
        target = ROOT/'sources'/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROJECT/name, target)
        assert sha(target) == hashes[name]
    shutil.copyfile(INPUTS, ROOT/'inputs.csv')
    shutil.copyfile(PROJECT/'roms/sheriff.bin', ROOT/'sheriff.bin')
    assert (ROOT/'sheriff.bin').stat().st_size == 0x4800
    project, root, work = linux(PROJECT), linux(ROOT), linux(WORK)
    source_args = ' '.join('"$work/source/'+name+'"' for name in SOURCES[:7])
    script = f'''#!/usr/bin/env bash
set -euo pipefail
project="{project}"
root="{root}"
work="{work}"
trap 'code=$?; printf "%s\\n" "$code" > "$root/workflow-exit-code.txt"' EXIT
test ! -e "$work"
mkdir -p "$work/source"
cp -R "$root/sources/." "$work/source/"
printf 'build\\n' > "$root/phase.txt"
verilator --version > "$root/toolchain.txt"
g++ --version >> "$root/toolchain.txt"
cd "$work/source"
verilator -Wall -Wno-fatal --assert --timing --threads 1 --x-initial unique --x-assign unique \\
 --cc --exe --build -j 2 -I"$work/source/rtl" -CFLAGS '-O2 -std=c++17' \\
 --top-module n8080_board --Mdir "$work/model" {source_args} > "$root/build.log" 2>&1
cp "$work/model/Vn8080_board" "$root/Vn8080_board"
sha256sum "$root/Vn8080_board" > "$root/model.sha256"
printf 'native1201\\n' > "$root/phase.txt"
/bin/bash "$work/source/tools/run_native_with_receipt.sh" "$root/native-exit-code.txt" \\
 /usr/bin/env SHERIFF_BUS_FRAMES=1000,1040,1070 \\
 "$root/Vn8080_board" "$root/sheriff.bin" "$root/native" {FRAMES} "$root/inputs.csv" \\
 +verilator+seed+1 > "$root/run.log" 2>&1
printf 'complete\\n' > "$root/phase.txt"
'''
    (ROOT/'build_run.sh').write_text(script, encoding='utf-8', newline='')
    manifest = dict(started_utc=now(), host_pid=os.getpid(), source_sha256=hashes,
                    inputs_sha256=sha(INPUTS), rom_sha256=sha(ROOT/'sheriff.bin'),
                    frames_requested=FRAMES, seed=1, root_clock_hz=50400000,
                    reset_load_clocks=18432, reset_hold_clocks=1000,
                    flags='--assert --timing --threads 1 --x-initial unique --x-assign unique -j2 -O2 -std=c++17',
                    source_closure_order=SOURCES, snapshot_root=str(ROOT/'sources'),
                    volatile_root=str(WORK), evidence_tier='saved-same-side-integration-regression',
                    headless=True, display_backend='none',
                    runner_sha256=sha(Path(__file__)), shell_sha256=sha(ROOT/'build_run.sh'))
    write(ROOT/'launch.json', manifest)
    code, error = 1, None
    try:
        command = ['wsl.exe', '-d', 'Ubuntu', '--cd', str(PROJECT), '--exec', '/bin/bash', root+'/build_run.sh']
        with (ROOT/'worker.stdout.log').open('wb') as stdout, (ROOT/'worker.stderr.log').open('wb') as stderr:
            child = subprocess.Popen(command, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
            write(ROOT/'child.json', dict(pid=child.pid, started_utc=now(), command=command))
            code = child.wait()
    except Exception as exception:
        error = repr(exception)
    receipt = dict(manifest, finished_utc=now(), workflow_exit=code, error=error,
                   native_OS_exit=int((ROOT/'native-exit-code.txt').read_text()) if (ROOT/'native-exit-code.txt').exists() else None,
                   source_changed_during_run=[name for name in SOURCES if sha(PROJECT/name)!=hashes[name]],
                   model_sha256=sha(ROOT/'Vn8080_board') if (ROOT/'Vn8080_board').exists() else None)
    write(ROOT/'terminal.json', receipt)
    if code or error or receipt['source_changed_during_run'] or receipt['native_OS_exit'] != 0:
        raise RuntimeError(f'Current gain integration execution failed: {receipt}')
    try:
        comparison = compare(receipt)
        write(ROOT/'comparison-terminal.json', dict(exit_code=0, finished_utc=now(), result=comparison))
        print(json.dumps(comparison))
    except Exception as exception:
        write(ROOT/'comparison-terminal.json', dict(exit_code=1, finished_utc=now(), error=repr(exception)))
        raise


if __name__ == '__main__':
    main()
