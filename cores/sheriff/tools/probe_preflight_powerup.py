#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Observe a saved native Preflight model without changing its RTL or state.

Copies generated sources outside .preflight, adds read-only scalar sampling to
the harness, then replays the same boot script for board and hostile power-up.
This is diagnostic evidence for the saved model, not final-source qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--preflight-root', type=Path, required=True)
parser.add_argument('--saved-run', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--milliseconds', type=int, default=80)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
assert output.is_relative_to(root), 'Diagnostic files must stay in this project'
output.mkdir(parents=True, exist_ok=False)
app = args.preflight_root.resolve()
cache = output / 'cache'
cache.mkdir()
obj = cache / 'obj'
obj.mkdir()
saved = root / '.preflight/cache'
for source in (saved / 'obj').glob('Vpf_tb*'):
    if source.suffix in ('.cpp', '.h'):
        shutil.copy2(source, obj / source.name)
shutil.copy2(saved / 'pf_state.cpp', cache / 'pf_state.cpp')
models = output / 'private-harness'
(models / 'board').mkdir(parents=True)
harness = (app / 'board/harness.cpp').read_text()
anchor = '    apply_powerup(top->rootp);'
assert harness.count(anchor) == 1
observe_setup = r'''
    PfVar* observed = nullptr;
    int observed_n = pf_state_vars(top->rootp, &observed);
    std::vector<int> selected;
    int rgb_index = -1;
    for (int i = 0; i < observed_n; ++i) {
        std::string n = observed[i].name;
        if (n == "emu.board_rgb") rgb_index = i;
        if (observed[i].is_array || observed[i].bytes > 8) continue;
        if (n.find("gamma") != std::string::npos ||
            n.find("pll") != std::string::npos ||
            n.find("reset") != std::string::npos ||
            n.find("paused") != std::string::npos || n == "emu.hs_pause" ||
            n == "emu.rom_loaded" || n == "emu.loading" ||
            n == "emu.board_rgb" || n == "emu.board.color_mode" ||
            n.find("video.mixer") != std::string::npos ||
            n == "emu.video.geometry_active") selected.push_back(i);
    }
    FILE* observation = openf("state_probe.csv", "w");
    fprintf(observation, "ns,board_rgb_nonzero_evals");
    for (int i : selected) fprintf(observation, ",%s", observed[i].name);
    fprintf(observation, "\n");
    double next_probe_ns = 0;
    uint64_t nonzero_rgb = 0;
'''
harness = harness.replace(anchor, anchor + observe_setup)
anchor = '        top->eval();'
assert harness.count(anchor) == 1
observe_loop = r'''
        if (rgb_index >= 0 && *(const unsigned char*)observed[rgb_index].p) ++nonzero_rgb;
        if (now_ns() >= next_probe_ns) {
            fprintf(observation, "%.0f,%llu", now_ns(), (unsigned long long)nonzero_rgb);
            for (int i : selected) {
                uint64_t value = 0;
                memcpy(&value, observed[i].p, observed[i].bytes);
                fprintf(observation, ",%llu", (unsigned long long)value);
            }
            fprintf(observation, "\n");
            next_probe_ns += 50000;
        }
'''
harness = harness.replace(anchor, anchor + observe_loop)
harness = harness.replace('    top->final();', '    fclose(observation);\n    top->final();')
(models / 'board/harness.cpp').write_text(harness)
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
receipt = {
    'scope': 'Read-only sampled state of the saved full-wrapper generated model',
    'saved_manifest': json.loads((saved / 'manifest.json').read_text())['source_hash'],
    'generated_sources_sha256': {p.name: sha(p) for p in sorted(obj.iterdir())},
    'original_harness_sha256': sha(app / 'board/harness.cpp'),
    'probe_harness_sha256': sha(models / 'board/harness.cpp'),
    'rtl_changed': False, 'state_forced': False,
}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
sys.path.insert(0, str(app / 'src'))
from preflight import build, util, runner
util.setup_env()
build.APP = models
build.shared_cache = lambda ignored=None: output / 'runtime-cache'
result = build.compile_model(obj, cache, dict(os.environ), output / 'build.log')
if result.returncode:
    (output / 'exit_code.txt').write_text(str(result.returncode))
    raise SystemExit(result.returncode)
cfg = dict(line.split('=', 1) for line in (args.saved_run / 'run.cfg').read_text().splitlines() if '=' in line)
cfg.update(max_sim_ms=args.milliseconds, frames_after_boot=-1, dump_sdram=0, dump_vars=1)
results = runner.run_matrix(obj / 'pfsim.exe', output / 'sim', cfg,
                           (args.saved_run / 'boot.script').read_text(),
                           [1], ['board', 'hostile'], budget_s=180, jobs=2)
(output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
(output / 'exit_code.txt').write_text(str(int(any(r['exit_code'] for r in results))))
print('State probe complete:', output)
