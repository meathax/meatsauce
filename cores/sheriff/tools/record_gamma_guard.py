#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bind gamma startup qualification to the terminal current-source wrapper run."""
import json
import subprocess
from pathlib import Path
from record_current_gameplay import sha


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    output = Path('docs/evidence/sheriff_gamma_guard.json')
    initial = load(output)
    assert initial['unit_receipt']['exit_code'] == 0
    for name, digest in initial['sha256'].items():
        assert sha(Path(name)) == digest
    run = Path('.preflight/runs/20261010-035814')
    summary = load(run / 'report/summary.json')
    findings = load(run / 'report/findings.json')
    job = load(Path('.preflight/job/job.json'))
    terminal = load(Path('.preflight/job/result.json'))
    assert job == initial['preflight_job'] and terminal['exit'] == 0
    assert summary['verdict'] == 'PASS' and summary['mode'] == 'Verify F-001'
    assert summary['n_runs'] == 2 and summary['profiles'] == ['hostile']
    assert not any(f['class'] == 'powerup.boot_depends_on_powerup' for f in findings)
    assert not any(f['severity'] == 'blocker' for f in findings)
    manifest = load(Path('.preflight/cache/manifest.json'))
    assert manifest['source_hash'] == summary['source_hash']
    assert 'n8080_gamma_guard.sv' in json.dumps(manifest['files'])
    subprocess.run(['git', 'diff', '--exit-code', '--', 'sys'], check=True,
                   stdout=subprocess.DEVNULL)
    check = Path('_checks/gamma-guard-20261010')
    # Preserve the terminal worker receipt before a later Preflight job replaces it.
    saved = check / 'verify-terminal.json'
    saved.write_text(json.dumps(dict(job=job, result=terminal), indent=2) + '\n')
    paths = [Path(__file__), run / 'report/summary.json', run / 'report/findings.json',
             saved, Path('.preflight/cache/manifest.json'), Path('.preflight/cache/build.json'),
             Path('Nintendo8080.sv'), Path('rtl/vendor/hiscore/hiscore.v')]
    profiles = {}
    for label in ('hostile-s1', 'hostile-s2'):
        profile = run / 'sim' / label
        profiles[label] = load(profile / 'sim_summary.json')
        paths += [profile / name for name in ('sim_summary.json', 'frames.jsonl',
                                              'hps_transcript.jsonl', 'run.cfg')]
    result = dict(initial,
                  scope='Gamma guard unit and current-source full-wrapper hostile seeds1/2,120 fields each.',
                  preflight_terminal=terminal, preflight_source_hash=summary['source_hash'],
                  preflight_run=run.as_posix(), wrapper_profile_summaries=profiles,
                  boot_ladder=summary['ladder'], remaining_findings=findings,
                  original_powerup_finding_absent=True, preflight_pass=True,
                  additional_sha256={p.as_posix(): sha(p) for p in paths},
                  limitations=['Finding IDs are report-local: the latest F-001 is informational syntax compatibility.',
                               '120-field boot/picture qualification; the input-response warning remains.',
                               'Cached framework declaration-order compatibility patch is simulation-only; sys/ is untouched.',
                               'No full gameplay, waveform equivalence or physical timing qualification.',
                               'Exact-current-source fit/STA/resource reports require the approved preassembly queue recipe.'],
                  timing_resource_pass=False, release_qualified=False, rbf_built=False)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(unit_exit=0, wrapper_exit=0, hostile_boots=2,
                          fields_per_boot=120, source_hash=summary['source_hash'],
                          report=output.as_posix())))


if __name__ == '__main__':
    main()
