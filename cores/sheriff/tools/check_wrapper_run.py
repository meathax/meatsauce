#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bounded read-only observation of an owned wrapper run and exact PID identity."""
import argparse
import ast
from datetime import datetime, timezone
import json
from pathlib import Path
from types import SimpleNamespace


def last_complete_line(path):
    with path.open('rb') as stream:
        stream.seek(max(0, path.stat().st_size - 8192))
        rows = stream.read().split(b'\n')
    return next((row.decode() for row in reversed(rows[:-1]) if row), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launch', type=Path, required=True)
    parser.add_argument('--run-root', type=Path, required=True)
    args = parser.parse_args()
    launch = json.loads(args.launch.read_text(encoding='utf-8-sig'))
    normalized = args.launch.with_name('identity-' + args.launch.name)
    normalized.write_text(json.dumps(dict(launch, started=launch['started_utc'])) + '\n')
    # Reuse the already qualified Windows FILETIME/exit-code identity guard.
    source = Path('tools/compare_streaming_video.py').read_text()
    node = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)
                and n.name == 'producer_live')
    scope = dict(json=json, Path=Path, datetime=datetime, timezone=timezone,
                 args=SimpleNamespace(watch_launch=normalized))
    exec(compile(ast.Module(body=[node], type_ignores=[]), 'producer_live', 'exec'), scope)
    live = scope['producer_live']()
    profile = args.run_root / 'sim/hostile-s1'
    last_frame = last_complete_line(profile / 'frames.jsonl')
    terminal_path = Path(launch['output']) / 'terminal.json'
    terminal = json.loads(terminal_path.read_text()) if terminal_path.exists() else None
    result = dict(checked_utc=datetime.now(timezone.utc).isoformat(),
                  launch=args.launch.as_posix(), worker_identity_live=live,
                  run_root=args.run_root.as_posix(), last_frame=json.loads(last_frame) if last_frame else None,
                  last_cpu_observation=last_complete_line(profile / 'input_probe.csv'),
                  terminal=terminal)
    output = args.launch.with_name('identity-check-' + args.launch.stem + '.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(worker_identity_live=live,
                          last_frame=result['last_frame']['frame'] if result['last_frame'] else None,
                          terminal=terminal, evidence=output.as_posix())))


if __name__ == '__main__':
    main()
