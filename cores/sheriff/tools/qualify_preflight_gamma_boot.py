#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Replay the saved observed simulator with one ordinary HPS gamma command.

Retains the failing boot alongside its treatment. No internal state writes,
ROM/RAM patches, finding waivers, installed-tool edits or Quartus invocation.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
import math
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--preflight-root', type=Path, required=True)
parser.add_argument('--probe', type=Path, required=True)
parser.add_argument('--saved-run', type=Path, required=True)
parser.add_argument('--passing-run', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--analyze-only', action='store_true', help='Review saved terminal runs without repeating simulation')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
assert output.is_relative_to(root)
if not args.analyze_only:
    output.mkdir(parents=True, exist_ok=False)
sys.path.insert(0, str(args.preflight_root.resolve() / 'src'))
from preflight import runner, util
util.setup_env()
reference = [json.loads(line) for line in (args.passing_run / 'frames.jsonl').read_text().splitlines()]
first_picture = next(row['t_ms'] for row in reference if row['nonblack'])
duration = max(400, math.ceil((first_picture + 100) / 100) * 100)
cfg = dict(line.split('=', 1) for line in (args.saved_run / 'run.cfg').read_text().splitlines() if '=' in line)
cfg.update(max_sim_ms=duration, frames_after_boot=-1, dump_sdram=0, dump_vars=1, budget_s=300)
script = (args.saved_run / 'boot.script').read_text()
anchor = 'mark boot_done'
assert script.count(anchor) == 1
treated = script.replace(anchor, 'uio 0x32 0x0   # UIO_SET_GAMMA: explicit disabled configuration\n' + anchor)
binary = args.probe / 'cache/obj/pfsim.exe'
cases = [('board-original', 'board', script),
         ('hostile-original', 'hostile', script),
         ('hostile-gamma-off', 'hostile', treated)]
prior = ({Path(row['run_dir']).name: row for row in json.loads((output / 'result.json').read_text())['cases']}
         if args.analyze_only else {})

def run(case):
    name, profile, boot = case
    directory = output / name
    result = (dict(prior[name]) if args.analyze_only else
              runner.run_one(binary.resolve(), directory, cfg, boot, 1, profile, timeout=420))
    frames = [json.loads(line) for line in (directory / 'frames.jsonl').read_text().splitlines()]
    rows = [row for row in csv.DictReader((directory / 'state_probe.csv').open()) if None not in row.values()]
    result['nonblack_frames'] = sum(row['nonblack'] for row in frames)
    # The first hostile frame is a partial field with random pipeline state,
    # while native board RGB is still zero. Keep that artifact in the report;
    # attribute the later black picture only once the reference draws the game.
    late_frames = [row for row in frames if row['t_ms'] >= first_picture]
    result['stable_game_frames'] = len(late_frames)
    result['stable_nonblack_frames'] = sum(row['nonblack'] for row in late_frames)
    result['first_nonblack_ms'] = next((row['t_ms'] for row in frames if row['nonblack']), None)
    result['native_rgb_nonzero_evals'] = int(rows[-1]['board_rgb_nonzero_evals'])
    result['gamma_enable_values'] = sorted({int(row['emu.hps_io.gamma_en']) for row in rows})
    result['final_gamma_enable'] = int(rows[-1]['emu.hps_io.gamma_en'])
    print(name, 'exit', result['exit_code'], 'native RGB events', result['native_rgb_nonzero_evals'],
          'nonblack frames', result['nonblack_frames'], flush=True)
    return result

with ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(run, cases))
passes = (all(row['exit_code'] == 0 for row in results)
          and all(row['native_rgb_nonzero_evals'] > 0 for row in results)
          and all(row['stable_game_frames'] >= 8 for row in results)
          and results[0]['stable_nonblack_frames'] == results[0]['stable_game_frames']
          and results[1]['stable_nonblack_frames'] == 0
          and results[2]['stable_nonblack_frames'] == results[2]['stable_game_frames']
          and results[2]['final_gamma_enable'] == 0)
receipt = {'scope': 'Saved full-wrapper model gamma initialization attribution, seed 1',
           'milliseconds': duration, 'reference_first_picture_ms': first_picture,
           'saved_source_hash': json.loads((args.probe / 'receipt.json').read_text())['saved_manifest'],
           'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
           'cases': results, 'gamma_cause_qualified_for_saved_model': passes,
           'complete_sheriff': False, 'current_source_boot_qualified': False,
           'limits': 'One saved generated model and seed; stable picture begins at the independent reference first game picture. The early partial-field artifact is retained. No actual hardware result or original PLL bisection validation.'}
suffix = '-reviewed' if args.analyze_only else ''
(output / ('result' + suffix + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
(output / ('exit_code' + suffix + '.txt')).write_text(str(int(not passes)))
raise SystemExit(int(not passes))
