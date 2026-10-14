#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run current full-wrapper RTL with frozen P1 inputs sent over ordinary HPS.

The installed builder generates/compiles the current project. A private host
observer links those same model objects and the matching bundled runtime. It
observes CPU DBIN/game RAM; it never forces RTL state or changes platform models.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def joystick(port, fire):
    # Sheriff movement R,L,U,D -> standard MiSTer R,L,D,U.
    move = (port & 3) | ((port & 4) << 1) | ((port & 8) >> 1)
    return move | ((port & 0xf0) << 4) | (16 if fire else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reuse-model-from', type=Path,
                        help='Reuse model objects from a terminal observer build failure before simulation')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    output = args.output.resolve()
    assert output.is_relative_to(root)
    output.mkdir(parents=True, exist_ok=False)
    app = Path('D:/Arcade/AI/MISTERDEBUG')
    frozen = json.loads(Path('_checks/current-gameplay-1201-20261010/terminal.json').read_text(encoding='utf-8-sig'))
    inputs = Path(frozen['inputs'])
    assert sha(inputs) == frozen['inputs_sha256']
    with inputs.open(newline='') as stream:
        events = [dict((k, int(v)) for k, v in row.items()) for row in csv.DictReader(stream)
                  if int(row['frame']) <= 1201]
    assert all(e['dip'] == 252 for e in events)
    assert events[0] == dict(frame=0, p0=0, p1=0, p2=0, dip=252)
    assert all(e['p2'] & ~0x8f == 0 for e in events)
    tracked = subprocess.check_output(['git', 'ls-files', '*.sv', '*.v', '*.vhd', '*.qip',
                                      '*.qsf', '*.sdc', '*.qpf']).decode().splitlines()
    source_hashes = {name: sha(name) for name in tracked}
    receipt = dict(scope='Current full MiSTer wrapper, P1 frozen input scenario through1201 fields.',
                   inputs=inputs.as_posix(), inputs_sha256=sha(inputs),
                   source_sha256=source_hashes, frames_requested=1201,
                    observer_script_sha256=sha(__file__), started_unix=time.time(),
                    neutral_analog_via_hps=True,
                   state_forced=False, platform_models_changed=False,
                   quartus_used=False, rbf_built=False)
    write_json(output / 'receipt.json', receipt)
    sys.path.insert(0, str(app / 'src'))
    from preflight import build, hps, runner, util
    util.setup_env()
    original_boot, original_compile, original_run = hps.boot_script, build.compile_model, runner.run_one
    observed_binary = output / 'observed-pfsim.exe'
    if args.reuse_model_from:
        prior = args.reuse_model_from.resolve()
        assert prior.is_relative_to(root)
        assert json.loads((prior / 'terminal.json').read_text())['exit_code'] == 2
        assert not (prior / 'native-result.json').exists(), 'Simulation already ran; do not repeat it'
        prior_receipt = json.loads((prior / 'receipt.json').read_text())
        assert prior_receipt['source_sha256'] == source_hashes
        prior_build = json.loads((prior / 'observer-build.json').read_text())
        assert prior_build['exit_code'] != 0
        for name, digest in prior_build['objects_sha256'].items():
            assert sha(name) == digest
        receipt['reused_after_terminal_observer_failure'] = prior.as_posix()

    def gameplay_boot(*positional, **keywords):
        script = original_boot(*positional, **keywords)
        assert script.count('mark boot_done') == 1
        script = script.split('mark boot_done')[0]
        # Digital-only stimulus still needs explicit centered analog channels:
        # hps_io retains these registers until firmware writes them.
        for command in (0x1a, 0x3d):
            for player in (0, 1):
                script += f'uio {command:#x} {player} 0\n'
        script += 'mark boot_done\n'
        for event in events:
            p2 = event['p2']
            joy0 = joystick(event['p0'], p2 & 1)
            joy0 |= (32 if p2 & 4 else 0) | (64 if p2 & 8 else 0) | (128 if p2 & 128 else 0)
            joy1 = joystick(event['p1'], p2 & 2)
            script += (f"wait_after_boot {event['frame']}\n"
                       f"uio 0x02 {joy0:#x} 0x0\n"
                       f"uio 0x03 {joy1:#x} 0x0\n")
        (output / 'boot.script').write_text(script, encoding='utf-8', newline='\n')
        receipt['boot_script_sha256'] = sha(output / 'boot.script')
        write_json(output / 'receipt.json', receipt)
        return script

    def compile_observed(obj, cache, env, log):
        result = (type('R', (), dict(returncode=0))() if args.reuse_model_from
                  else original_compile(obj, cache, env, log))
        assert result.returncode == 0, 'Current RTL build must pass before the observer links'
        obj, cache = Path(obj), Path(cache)
        header = (obj / 'Vpf_tb___024root.h').read_text()
        fields = dict(joy='pf_tb__DOT__emu__DOT__joy0',
                      dbin='pf_tb__DOT__emu__DOT__board__DOT__processor__DOT__cpu__DOT__dbin_pin',
                      pc='pf_tb__DOT__emu__DOT__board__DOT__processor__DOT__cpu__DOT__r16_pc',
                      status='pf_tb__DOT__emu__DOT__board__DOT__cpu_status',
                      din='pf_tb__DOT__emu__DOT__board__DOT__cpu_din',
                      paused='pf_tb__DOT__emu__DOT__game_paused',
                      ram='pf_tb__DOT__emu__DOT__board__DOT__ram')
        assert all(name + ';' in header for name in fields.values())
        harness = (app / 'board/harness.cpp').read_text()
        assert harness.count('    apply_powerup(top->rootp);') == 1
        harness = harness.replace('    apply_powerup(top->rootp);', '''    apply_powerup(top->rootp);
    FILE* input_observation=openf("input_probe.csv","w");
    fprintf(input_observation,"ns,kind,joy0,status,din,pc,paused\\n");
    FILE* ram_observation=openf("game_ram_probe.csv","w");
    fprintf(ram_observation,"ns,ram_6000_603f_hex\\n");
    unsigned observed_joy=~0U;bool observed_dbin=false;double next_ram_ns=0;
''')
        assert harness.count('        top->eval();') == 1
        loop = '''
        const auto* r=top->rootp;
        bool io_edge=r->@dbin@&&!observed_dbin&&(r->@status@&0x40);
        if(r->@joy@!=observed_joy||io_edge){
            fprintf(input_observation,"%.0f,%s,%u,%u,%u,%u,%u\\n",now_ns(),
                io_edge?"cpu_io_read":"joystick",r->@joy@,r->@status@,
                r->@din@,r->@pc@,r->@paused@);fflush(input_observation);
        }
        observed_joy=r->@joy@;observed_dbin=r->@dbin@;
        if(now_ns()>=next_ram_ns){
            fprintf(ram_observation,"%.0f,",now_ns());
            for(unsigned a=0x2000;a<0x2040;++a)fprintf(ram_observation,"%02x",r->@ram@[a]);
            fprintf(ram_observation,"\\n");fflush(ram_observation);next_ram_ns+=16253968;
        }
'''
        for name, field in fields.items():
            loop = loop.replace('@' + name + '@', field)
        assert '@' not in loop
        harness = harness.replace('        top->eval();', '        top->eval();' + loop)
        assert harness.count('    top->final();') == 1
        harness = harness.replace('    top->final();',
                                  '    fclose(input_observation);fclose(ram_observation);\n    top->final();')
        private = output / 'observed-harness.cpp'
        private.write_text(harness, encoding='utf-8', newline='\n')
        cxx = build.cxx_compiler(env)
        include = build.verilator_include()
        runtime_base = [cxx, '-std=c++20', '-I' + str(include), '-I' + str(include / 'vltstd'),
                        *[d for d in build.DEFS if 'TOP' not in d], *build.WARN]
        runtime_tag = hashlib.sha256((' '.join(runtime_base) + str(include)).encode()).hexdigest()[:12]
        runtime = build.shared_cache(cache) / 'vlt_runtime' / runtime_tag
        model_objects = sorted(p for p in obj.glob('*.o') if p.name != 'harness.o')
        runtime_objects = [runtime / name for name in ('sc_time_stamp.o', 'verilated.o',
                            'verilated_dpi.o', 'verilated_threads.o', 'verilated_timing.o')]
        assert model_objects and all(p.is_file() for p in runtime_objects)
        argv = [str(cxx), '-O2', '-std=c++20',
                '-I' + str(obj), '-I' + str(include), '-I' + str(include / 'vltstd'),
                '-I' + str(app / 'board'), *build.DEFS, *build.WARN, str(private),
                *map(str, model_objects + runtime_objects), '-pthread', '-static-libgcc',
                '-static-libstdc++', '-o', str(observed_binary)]
        with (output / 'observer-build.stdout.log').open('w') as out, (output / 'observer-build.stderr.log').open('w') as err:
            built = subprocess.run(argv, env=env, stdout=out, stderr=err)
        write_json(output / 'observer-build.json', dict(exit_code=built.returncode, argv=argv,
                   objects_sha256={p.as_posix(): sha(p) for p in model_objects + runtime_objects}))
        assert built.returncode == 0
        assert observed_binary.read_bytes()[:2] == b'MZ'
        receipt.update(model_binary_sha256=sha(obj / 'pfsim.exe'),
                       observed_binary_sha256=sha(observed_binary),
                       private_harness_sha256=sha(private),
                       preflight_source_hash=json.loads((cache / 'manifest.json').read_text())['source_hash'])
        write_json(output / 'receipt.json', receipt)
        return result

    def observed_run(binary, *positional, **keywords):
        assert observed_binary.is_file(), 'Fresh observed build required'
        assert sha(observed_binary) == receipt['observed_binary_sha256']
        result = original_run(observed_binary, *positional, **keywords)
        write_json(output / 'native-result.json', result)
        return result

    hps.boot_script, build.compile_model, runner.run_one = gameplay_boot, compile_observed, observed_run
    if args.reuse_model_from:
        def reuse_current_model(manifest, out_root, **keywords):
            cache = Path(out_root) / 'cache'
            assert manifest['source_hash'] == json.loads((cache / 'manifest.json').read_text())['source_hash']
            compile_observed(cache / 'obj', cache, dict(os.environ), output / 'reused-model.log')
            return cache / 'obj/pfsim.exe'
        build.build = reuse_current_model
    from preflight.cli import main as preflight_main
    argv = ['--repo', str(root), '--roms', 'D:/Arcade/AI/MAME 0.289 ROMs (merged)',
            '--foreground', '--profile', 'hostile', '--seeds', '1', '--frames', '1201',
            '--save-every', '60', '--budget', '7200', '--no-diagnose', '--no-inputs', '--rebuild', '--force']
    receipt['cli_arguments'] = argv
    write_json(output / 'receipt.json', receipt)
    try:
        code = preflight_main(argv)
        # Custom boot-script adapters are outside Preflight's source/settings
        # result-cache identity. A cached CLI PASS is not a native execution.
        if not (output / 'native-result.json').is_file():
            raise RuntimeError(f'Preflight returned {code} without executing the requested native scenario')
        changed = [name for name, digest in source_hashes.items() if sha(name) != digest]
        write_json(output / 'terminal.json', dict(exit_code=code, finished_unix=time.time(),
                   source_changed_during_run=changed, complete_sheriff=False, rbf_built=False))
        return code
    except Exception as error:
        write_json(output / 'terminal.json', dict(exit_code=2, finished_unix=time.time(),
                   error=repr(error), complete_sheriff=False, rbf_built=False))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
