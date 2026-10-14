#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Finish the installed HTML reporter from terminal evidence, without reruns.

Run with Python -X utf8. Calls the original reporting API; does not alter
simulation results, findings, models, core source or the .preflight/latest link.
"""
import argparse
import json
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--preflight-root', type=Path, required=True)
parser.add_argument('--run', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
assert sys.flags.utf8_mode, 'Run this recovery with Python -X utf8'
root = Path(__file__).resolve().parents[1]
run = args.run.resolve()
assert run.is_relative_to(root / '.preflight/runs')
assert args.receipt.resolve().is_relative_to(root)
report_dir = run / 'report'
ctx = json.loads((report_dir / 'summary.json').read_text(encoding='utf-8'))
ctx['findings'] = json.loads((report_dir / 'findings.json').read_text(encoding='utf-8'))
primary = run / 'sim' / ctx['primary_run']
ctx['timing_rows'] = [json.loads(line) for line in (primary / 'frames.jsonl').read_text().splitlines()]
cases = []
for directory in sorted((run / 'sim').iterdir()):
    if not directory.is_dir(): continue
    case = json.loads((directory / 'sim_summary.json').read_text())
    assert case['stop_reason'] == 'frames_after_boot' and case['frames'] == 120
    cases.append({'name': directory.name, 'summary': case})
assert len(cases) == ctx['n_runs'] == 4
sys.path.insert(0, str(args.preflight_root.resolve() / 'src'))
from preflight import report
report.html_report(ctx, report_dir / 'report.html')
receipt = {'action': 'UTF-8 report-only recovery with installed report.html_report',
           'simulation_repeated': False, 'findings_changed': False,
           'source_hash': ctx['source_hash'], 'simulator_verdict': ctx['verdict'],
           'cases': cases, 'report': str(report_dir / 'report.html'),
           'report_bytes': (report_dir / 'report.html').stat().st_size,
           'latest_link_updated': False}
args.receipt.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
print('Recovered HTML:', receipt['report'], receipt['report_bytes'], 'bytes')
print('Saved simulator verdict:', receipt['simulator_verdict'])
