#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Observe ordinary HPS coin/start on the saved full-wrapper model.

Reuses generated RTL C++ without regeneration. Only a private copy of the host
harness gains read-only observations; neither RTL nor simulator state is patched.
The early generic probe is retained, followed by the existing gameplay fixture's
600/690-frame coin/start schedule and a short independent movement/aim/fire action.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight-root', type=Path, required=True)
    parser.add_argument('--saved-run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cxx', type=Path, help='Explicit native Windows C++ compiler')
    parser.add_argument('--replay-only', action='store_true',
                        help='Reuse an existing observed binary after a terminal runtime failure')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    assert output.is_relative_to(root)
    if args.replay_only:
        assert args.cxx, 'Replay requires explicit compiler/runtime routing'
        receipt = json.loads((output / 'receipt.json').read_text())
        binary = output / 'cache/obj/pfsim.exe'
        assert sha(binary) == receipt['binary_sha256']
        assert sha(output / 'private-harness/board/harness.cpp') == receipt['probe_harness_sha256']
        prior = json.loads((output / 'result.json').read_text())
        assert prior['exit_code'] != 0 and not prior.get('frames'), 'Do not repeat a live or completed simulation'
        previous = output / 'sim/board-s1'
        boot = (previous / 'boot.script').read_text()
        assert hashlib.sha256(boot.encode()).hexdigest() == receipt['boot_script_sha256']
        cfg = dict(line.split('=', 1) for line in (previous / 'run.cfg').read_text().splitlines() if '=' in line)
        sys.path.insert(0, str(args.preflight_root.resolve() / 'src'))
        from preflight import util, runner
        util.setup_env()
        os.environ['PATH'] = str(args.cxx.resolve(strict=True).parent) + os.pathsep + os.environ['PATH']
        directory = output / 'sim/board-s1-routed'
        assert not directory.exists()
        replay_receipt = {'binary_sha256': sha(binary), 'previous_terminal_result': prior,
                          'runtime_path_prefix': str(args.cxx.resolve().parent),
                          'script_sha256': sha(Path(__file__)), 'state_forced': False,
                          'quartus_used': False}
        (output / 'replay-receipt.json').write_text(json.dumps(replay_receipt, indent=2) + '\n')
        print('Reusing compiled wrapper input observer with matching runtime:', directory, flush=True)
        result = runner.run_one(binary, directory, cfg, boot, 1, 'board', timeout=2520)
        (output / 'replay-result.json').write_text(json.dumps(result, indent=2) + '\n')
        (output / 'replay-exit_code.txt').write_text(str(result['exit_code']))
        print('Observed input replay terminal:', result['exit_code'], flush=True)
        return result['exit_code']
    output.mkdir(parents=True, exist_ok=False)
    app = args.preflight_root.resolve()
    saved = root / '.preflight/cache'
    manifest = json.loads((saved / 'manifest.json').read_text())
    cache = output / 'cache'
    obj = cache / 'obj'
    obj.mkdir(parents=True)
    for source in (saved / 'obj').glob('Vpf_tb*'):
        if source.suffix in ('.cpp', '.h'):
            shutil.copy2(source, obj / source.name)
    shutil.copy2(saved / 'pf_state.cpp', cache / 'pf_state.cpp')
    models = output / 'private-harness'
    (models / 'board').mkdir(parents=True)
    header = (obj / 'Vpf_tb___024root.h').read_text()
    fields = {
        'joy': 'pf_tb__DOT__emu__DOT__joy0',
        'dbin': 'pf_tb__DOT__emu__DOT__board__DOT__processor__DOT__cpu__DOT__dbin_pin',
        'pc': 'pf_tb__DOT__emu__DOT__board__DOT__processor__DOT__cpu__DOT__r16_pc',
        'status': 'pf_tb__DOT__emu__DOT__board__DOT__cpu_status',
        'din': 'pf_tb__DOT__emu__DOT__board__DOT__cpu_din',
        'paused': 'pf_tb__DOT__emu__DOT__game_paused',
        'reset_stretch': 'pf_tb__DOT__emu__DOT__reset_stretch',
        'ram': 'pf_tb__DOT__emu__DOT__board__DOT__ram',
    }
    for name in fields.values():
        assert name + ';' in header, name
    harness = (app / 'board/harness.cpp').read_text()
    anchor = '    apply_powerup(top->rootp);'
    assert harness.count(anchor) == 1
    setup = r'''
    FILE* input_observation = openf("input_probe.csv", "w");
    fprintf(input_observation, "ns,kind,joy0,status,din,pc,paused,reset_stretch\n");
    FILE* ram_observation = openf("game_ram_probe.csv", "w");
    fprintf(ram_observation, "ns,ram_6000_603f_hex\n");
    unsigned observed_joy = ~0U;
    bool observed_dbin = false;
    double next_game_ram_ns = 0;
'''
    harness = harness.replace(anchor, anchor + setup)
    anchor = '        top->eval();'
    assert harness.count(anchor) == 1
    loop = r'''
        const auto* input_root = top->rootp;
        unsigned current_joy = input_root->@joy@;
        bool current_dbin = input_root->@dbin@;
        bool io_edge = current_dbin && !observed_dbin && (input_root->@status@ & 0x40);
        if (current_joy != observed_joy || io_edge) {
            fprintf(input_observation, "%.0f,%s,%u,%u,%u,%u,%u,%u\n", now_ns(),
                io_edge ? "cpu_io_read" : "joystick", current_joy,
                input_root->@status@, input_root->@din@, input_root->@pc@,
                input_root->@paused@, input_root->@reset_stretch@);
            fflush(input_observation);
        }
        observed_joy = current_joy;
        observed_dbin = current_dbin;
        if (now_ns() >= next_game_ram_ns) {
            fprintf(ram_observation, "%.0f,", now_ns());
            for (unsigned a = 0x2000; a < 0x2040; ++a)
                fprintf(ram_observation, "%02x", input_root->@ram@[a]);
            fprintf(ram_observation, "\n");
            fflush(ram_observation);
            next_game_ram_ns += 16253968;
        }
'''
    for key, field in fields.items():
        loop = loop.replace('@' + key + '@', field)
    assert '@' not in loop
    harness = harness.replace(anchor, anchor + loop)
    anchor = '    top->final();'
    assert harness.count(anchor) == 1
    harness = harness.replace(anchor, '    fclose(input_observation);\n    fclose(ram_observation);\n' + anchor)
    private = models / 'board/harness.cpp'
    private.write_text(harness)
    boot = (args.saved_run / 'boot.script').read_text()
    assert boot.count('mark boot_done') == 1
    assert 'uio 0x32 0x0' in boot
    boot += '''wait_after_boot 600
uio 0x02 0x80 0x0   # existing gameplay fixture: coin
mark late_coin
wait_after_boot 605
uio 0x02 0x0 0x0
wait_after_boot 690
uio 0x02 0x20 0x0   # existing gameplay fixture: start 1
mark late_start
wait_after_boot 730
uio 0x02 0x0 0x0
wait_after_boot 740
uio 0x02 0x911 0x0  # move right, aim right/down, fire
mark move_aim_fire
wait_after_boot 760
uio 0x02 0x0 0x0
mark inputs_released
'''
    receipt = {
        'scope': 'Saved full MiSTer wrapper: ordinary HPS input events and read-only CPU/game RAM observations',
        'saved_source_hash': manifest['source_hash'],
        'saved_manifest_sha256': sha(saved / 'manifest.json'),
        'generated_sources_sha256': {p.name: sha(p) for p in sorted(obj.iterdir())},
        'original_harness_sha256': sha(app / 'board/harness.cpp'),
        'probe_harness_sha256': sha(private),
        'fields': fields,
        'boot_script_sha256': hashlib.sha256(boot.encode()).hexdigest(),
        'rtl_changed': False, 'state_forced': False, 'quartus_used': False,
        'complete_sheriff': False,
        'limits': 'One power-up profile/seed. CPU DBIN edge is observed, not forced. Graphics, physical raster timing, audio and release gates remain separate.',
    }
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    sys.path.insert(0, str(app / 'src'))
    from preflight import build, util, runner
    util.setup_env()
    build_env = dict(os.environ)
    if args.cxx:
        cxx = args.cxx.resolve(strict=True)
        build_env['CXX'] = str(cxx)
        build_env['PATH'] = str(cxx.parent) + os.pathsep + build_env['PATH']
        os.environ['PATH'] = build_env['PATH']
        receipt['cxx'] = str(cxx)
        receipt['cxx_sha256'] = sha(cxx)
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    build.APP = models
    build.shared_cache = lambda ignored=None: output / 'runtime-cache'
    result = build.compile_model(obj, cache, build_env, output / 'build.log')
    if result.returncode:
        (output / 'exit_code.txt').write_text(str(result.returncode))
        return result.returncode
    receipt['binary_sha256'] = sha(obj / 'pfsim.exe')
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    cfg = dict(line.split('=', 1) for line in (args.saved_run / 'run.cfg').read_text().splitlines() if '=' in line)
    cfg.update(max_frames=3000, frames_after_boot=780, save_every=30, budget_s=2400,
               dump_sdram=0, dump_vars=0)
    print('Running one 780-frame observed wrapper boot:', output, flush=True)
    result = runner.run_one((obj / 'pfsim.exe').resolve(), output / 'sim/board-s1', cfg,
                            boot, 1, 'board', timeout=2520)
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    (output / 'exit_code.txt').write_text(str(result['exit_code']))
    print('Wrapper input probe terminal:', result['exit_code'], flush=True)
    return result['exit_code']


if __name__ == '__main__':
    raise SystemExit(main())
