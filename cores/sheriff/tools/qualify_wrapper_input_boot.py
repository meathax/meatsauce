#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare untouched/centered HPS analog inputs using the current wrapper model."""
import csv
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil
from datetime import datetime, timezone


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('_checks/wrapper-analog-boot-20261010'))
    parser.add_argument('--reuse-probe-from', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    previous = Path('_checks/current-wrapper-gameplay-1201-20261010/run-v3')
    receipt = json.loads((previous / 'receipt.json').read_text())
    build = json.loads((previous / 'observer-build.json').read_text())
    assert build['exit_code'] == 0
    for name, digest in {**receipt['source_sha256'], **build['objects_sha256']}.items():
        assert sha(name) == digest, name
    assert sha(receipt['inputs']) == receipt['inputs_sha256']
    out = args.output.resolve()
    assert out.is_relative_to(root)
    out.mkdir(exist_ok=False)
    source = (previous / 'observed-harness.cpp').read_text()
    assert sha(previous / 'observed-harness.cpp') == receipt['private_harness_sha256']
    prefix = 'pf_tb__DOT__emu__DOT__'
    members = ['joy0', 'joy1', 'analog_l0', 'analog_l1', 'analog_r0', 'analog_r1']
    header = Path('.preflight/cache/obj/Vpf_tb___024root.h').read_text()
    assert all(prefix + m + ';' in header for m in members)
    source = source.replace('    FILE* input_observation=',
        '    FILE* controls_observation=openf("controls_probe.csv","w");\n'
        '    fprintf(controls_observation,"ns,joy0,joy1,analog_l0,analog_l1,analog_r0,analog_r1,rotate,paused\\n");\n'
        '    double next_controls_ns=0;\n    FILE* input_observation=', 1)
    fields = ','.join('r->' + prefix + m for m in members)
    hook = ('\n        if(now_ns()>=next_controls_ns){\n'
            '            fprintf(controls_observation,"%.0f,%u,%u,%u,%u,%u,%u,%u,%u\\n",now_ns(),'
            + fields + ',(r->' + prefix + 'status[0]>>11)&1,r->' + prefix + 'game_paused);\n'
            '            next_controls_ns+=1000;\n        }\n'
            '        if(now_ns()>=30000000)g_stop=true;\n')
    assert source.count('        const auto* r=top->rootp;') == 1
    source = source.replace('        const auto* r=top->rootp;', '        const auto* r=top->rootp;' + hook)
    source = source.replace('    top->final();', '    fclose(controls_observation);\n    top->final();')
    private, binary = out / 'probe.cpp', out / 'probe.exe'
    private.write_text(source, encoding='utf-8', newline='\n')
    argv = [str(private) if x == str(previous.resolve() / 'observed-harness.cpp') else x
            for x in build['argv']]
    assert str(private) in argv
    assert argv[-2] == '-o'
    argv[-1] = str(binary)
    sys.path.insert(0, 'D:/Arcade/AI/MISTERDEBUG/src')
    from preflight import build as preflight_build, util
    util.setup_env()
    env = os.environ.copy()
    # The builder also supplies the compiler's cc1plus/sysroot routing.
    compiler = preflight_build.cxx_compiler(env)
    assert Path(compiler).resolve() == Path(argv[0]).resolve()
    if args.reuse_probe_from:
        prior = args.reuse_probe_from.resolve()
        assert prior.is_relative_to(root)
        prior_build = json.loads((prior / 'build.json').read_text())
        assert prior_build['exit_code'] == 0
        assert prior_build['source_sha256'] == sha(private) == sha(prior / 'probe.cpp')
        assert prior_build['objects_sha256'] == build['objects_sha256']
        shutil.copyfile(prior / 'probe.exe', binary)
        write(out / 'build.json', dict(exit_code=None, compilation_executed=False,
              reused_probe_from=prior.as_posix(), reused_actual_compile_exit_code=0,
              reused_build_receipt_sha256=sha(prior / 'build.json'),
              observed_binary_sha256=sha(binary), source_sha256=sha(private),
              objects_sha256=build['objects_sha256']))
    else:
        with (out / 'build.stdout.log').open('wb') as stdout, (out / 'build.stderr.log').open('wb') as stderr:
            compiled = subprocess.run(argv, env=env, stdout=stdout, stderr=stderr,
                                      creationflags=subprocess.CREATE_NO_WINDOW)
        write(out / 'build.json', dict(exit_code=compiled.returncode, argv=argv,
              compilation_executed=True, objects_sha256=build['objects_sha256'], source_sha256=sha(private)))
        assert compiled.returncode == 0
    assert binary.read_bytes()[:2] == b'MZ'
    with Path(receipt['inputs']).open(newline='') as stream:
        vectors = list(dict.fromkeys(int(r['p0']) for r in csv.DictReader(stream)
                                    if int(r['frame']) <= 1201 and int(r['p0'])))
    assert len(vectors) == 14
    # These are ordinary MiSTer digital words; the Sheriff Up/Down permutation
    # is inverted at the host boundary, exactly as in the gameplay producer.
    def joy(value):
        return (value & 3) | ((value & 4) << 1) | ((value & 8) >> 1) | ((value & 0xf0) << 4)
    expected = [(joy(v), joy(vectors[-1-i])) for i, v in enumerate(vectors)]
    boot = (previous / 'boot.script').read_text().split('mark boot_done')[0]
    cfg = Path('.preflight/runs/20261010-043322/sim/hostile-s1/run.cfg').read_text()
    cases = []
    for label, centered in [('untouched', False), ('centered', True)]:
        directory = out / label
        directory.mkdir()
        (directory / 'frames').mkdir()
        script = boot
        if centered:
            # Left/right analog commands use index then packed signed X/Y.
            for command in (0x1a, 0x3d):
                for player in (0, 1):
                    script += f'uio {command:#x} {player} 0\n'
        script += 'mark boot_done\nwait_us 100\n'
        for j0, j1 in expected:
            script += f'uio 0x02 {j0:#x} 0\nuio 0x03 {j1:#x} 0\nwait_us 150\n'
        (directory / 'boot.script').write_text(script, newline='\n')
        (directory / 'run.cfg').write_text(cfg)
        started = datetime.now(timezone.utc).isoformat()
        with (directory / 'stdout.log').open('wb') as stdout, (directory / 'stderr.log').open('wb') as stderr:
            runtime = subprocess.run([str(binary), '+pf_dir=' + str(directory),
                '+verilator+rand+reset+2', '+verilator+seed+1'], env=env,
                stdout=stdout, stderr=stderr, timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
        write(directory / 'runtime-receipt.json', dict(exit_code=runtime.returncode,
              started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(),
              observed_binary_sha256=sha(binary)))
        assert runtime.returncode == 0
        with (directory / 'controls_probe.csv').open(newline='') as stream:
            observations = [dict((k, int(v)) for k, v in row.items()) for row in csv.DictReader(stream)]
        matching = [row for row in observations if (row['joy0'], row['joy1']) in expected]
        analog_nonzero = [r for r in matching if any(r[k] for k in members[2:])]
        observed_pairs = {(r['joy0'], r['joy1']) for r in matching}
        case = dict(label=label, centered_via_hps=centered, exit_code=runtime.returncode,
                    started_utc=started, finished_utc=datetime.now(timezone.utc).isoformat(),
                    expected_pairs=expected, all_digital_pairs_observed=set(expected).issubset(observed_pairs),
                    matching_observations=len(matching), matching_analog_nonzero=len(analog_nonzero),
                    first_matching_observation=matching[0] if matching else None,
                    rotate_zero=all(r['rotate'] == 0 for r in matching),
                    paused_zero=all(r['paused'] == 0 for r in matching),
                    evidence_sha256={p.as_posix(): sha(p) for p in
                        (directory / 'run.cfg', directory / 'boot.script', directory / 'controls_probe.csv')})
        write(directory / 'receipt.json', case)
        cases.append(case)
        print(json.dumps(case), flush=True)
        assert runtime.returncode == 0 and case['all_digital_pairs_observed']
        assert case['rotate_zero'] and case['paused_zero']
        assert (len(analog_nonzero) == 0) == centered
    result = dict(exit_code=0, scope='30ms each, real HPS analog/digital transaction paths on unchanged current wrapper objects.',
                  cases=cases, source_sha256=receipt['source_sha256'],
                  objects_sha256=build['objects_sha256'], observed_binary_sha256=sha(binary),
                  state_forced=False, platform_models_changed=False,
                  controls_unit_evidence='docs/evidence/sheriff_controls_protocol.json',
                  gameplay_qualified=False, mame_equivalence_qualified=False, rbf_built=False)
    write(out / 'terminal.json', result)


if __name__ == '__main__':
    main()
