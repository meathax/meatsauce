"""Repair only private C++ observer lambda scope; retain failed evidence."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from irq_ipl_recognition61_probe import ROOT, NAME, RESEARCH, CAPTURE, PRIVATE, sha, receipt


def main():
    assert os.name == 'posix'
    # This is a continuation of the original failed build, never a replay restart.
    while not (RESEARCH / (NAME + '_build_exit.json')).exists():
        time.sleep(5)
    initial = json.loads((RESEARCH / (NAME + '_build_exit.json')).read_text())
    assert initial['exit_code'] != 0
    assert not (RESEARCH / (NAME + '_running.json')).exists()
    job = json.loads((RESEARCH / (NAME + '_job.json')).read_text())
    old_source = json.loads((RESEARCH / (NAME + '_source.json')).read_text())
    build = Path(job['build_root'])
    hostfile = build / 'system_main.cpp'
    assert sha(hostfile) == old_source['generated_host_sha256']
    shutil.copy2(hostfile, PRIVATE / 'system_main_failed.cpp')
    host = hostfile.read_text()
    lines = [line for line in host.splitlines(keepends=True) if 'auto observe_ipl=[&]()' in line]
    assert len(lines) == 1 and host.count('    Valpha68kn_system top;\n') == 1
    host = host.replace(lines[0], '')
    host = host.replace('    Valpha68kn_system top;\n', '    Valpha68kn_system top;\n' + lines[0])
    hostfile.write_text(host)
    (PRIVATE / 'system_main.cpp').write_text(host)
    source = dict(old_source)
    source.update(generated_host_sha256=sha(hostfile),
                  failed_generated_host_sha256=old_source['generated_host_sha256'],
                  original_source_receipt_sha256=sha(RESEARCH / (NAME + '_source.json')),
                  repair_helper_sha256=sha(__file__),
                  source_changes='Move read-only observer lambda after top declaration. All frozen RTL and original tick calls unchanged.')
    receipt('source_v2', source)
    for rel, h in job['source_pins'].items():
        assert sha(ROOT / rel) == h
    make = ['make', '-C', 'obj', '-f', 'Valpha68kn_system.mk', '-j4']
    with open(CAPTURE / 'repair_build.log', 'w') as out:
        child = subprocess.Popen(make, cwd=build, stdout=out, stderr=subprocess.STDOUT)
        receipt('repair_build_running', dict(pid=child.pid, worker_pid=os.getpid(), command=make, started=time.time()))
        code = child.wait()
    receipt('repair_build_exit', dict(pid=child.pid, exit_code=code, ended=time.time()))
    assert code == 0
    exe = CAPTURE / (NAME + '_sim')
    shutil.copy2(build / 'obj' / (NAME + '_sim'), exe)
    rom = ROOT / 'roms/kyros/download.bin'
    inputs = ROOT / 'sim/captures/kyros/warm_reset960_refv2/frame_states.csv'
    assert sha(rom) == job['rom_sha256'] and sha(inputs) == job['input_trace_sha256']
    run = [str(exe), str(rom), '61', str(CAPTURE), 'gameplay', '--inputs', str(inputs)]
    with open(CAPTURE / 'run.log', 'w') as out:
        sim = subprocess.Popen(run, cwd=build, stdout=out, stderr=subprocess.STDOUT)
        receipt('running', dict(pid=sim.pid, worker_pid=os.getpid(), command=run,
                                executable_sha256=sha(exe), started=time.time()))
        code = sim.wait()
    receipt('exit', dict(pid=sim.pid, exit_code=code, executable_sha256=sha(exe), ended=time.time()))
    assert code == 0


if __name__ == '__main__':
    main()
