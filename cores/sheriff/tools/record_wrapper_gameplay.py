#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Record terminal full-wrapper observations without changing sample origins."""
import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt-dir', type=Path, required=True)
    parser.add_argument('--run-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = load(args.receipt_dir / 'receipt.json')
    terminal = load(args.receipt_dir / 'terminal.json')
    native_result = load(args.receipt_dir / 'native-result.json')
    assert terminal['exit_code'] == 0, 'Terminal failure must be diagnosed first'
    assert terminal['source_changed_during_run'] == []
    assert receipt['state_forced'] is False
    assert receipt['platform_models_changed'] is False
    for name, digest in receipt['source_sha256'].items():
        assert sha(name) == digest, f'Source changed: {name}'
    assert sha(receipt['inputs']) == receipt['inputs_sha256']
    binary = args.receipt_dir / 'observed-pfsim.exe'
    assert sha(binary) == receipt['observed_binary_sha256']
    profile = args.run_root / 'sim/hostile-s1'
    producer_boot = args.receipt_dir / 'boot.script'
    assert sha(producer_boot) == receipt['boot_script_sha256']
    # The runner writes Windows CRLF. Preserve both raw hashes while requiring
    # precisely the same commands/words, with only text newline conversion.
    assert (profile / 'boot.script').read_text() == producer_boot.read_text()
    assert native_result['exit_code'] == 0
    assert native_result['frames'] == receipt['frames_requested']
    rom = Path('roms/sheriff.bin').read_bytes()
    counts = collections.defaultdict(collections.Counter)
    first = {}
    joystick = []
    undecoded = paused_reads = 0
    with (profile / 'input_probe.csv').open(newline='') as stream:
        for row in csv.DictReader(stream):
            if row['kind'] == 'joystick':
                joystick.append(row)
                continue
            assert row['kind'] == 'cpu_io_read'
            if int(row['paused']):
                paused_reads += 1
            pc = int(row['pc'])
            # The observed PC is after the IN immediate operand fetch.
            if not (1 < pc < 0x4000 and rom[pc - 2] == 0xdb):
                undecoded += 1
                continue
            port, value = rom[pc - 1], int(row['din'])
            counts[port][value] += 1
            first.setdefault(f'{port}:{value}', row)
    with Path(receipt['inputs']).open(newline='') as stream:
        expected = {int(row['p0']) for row in csv.DictReader(stream)
                    if int(row['frame']) <= receipt['frames_requested'] and int(row['p0'])}
    actual = set(counts[0]) - {0}
    frames = [json.loads(line) for line in (profile / 'frames.jsonl').read_text().splitlines()]
    saved = []
    for path in sorted((profile / 'frames').glob('f*.raw')):
        header, data = path.read_bytes().split(b'\n', 1)
        fmt, width, height = header.split()
        assert fmt == b'PF3' and len(data) == int(width) * int(height) * 3
        saved.append(dict(path=path.as_posix(), sha256=sha(path), width=int(width),
                          height=int(height), nonzero_components=sum(x != 0 for x in data)))
    evidence = [Path(__file__), producer_boot, args.receipt_dir / 'receipt.json',
                args.receipt_dir / 'terminal.json', args.receipt_dir / 'native-result.json',
                profile / 'input_probe.csv', profile / 'game_ram_probe.csv',
                profile / 'frames.jsonl', profile / 'boot.script', binary]
    result = dict(scope='Terminal current full-wrapper hostile seed1, frozen P1 inputs through1201 fields.',
                  receipt=receipt, terminal=terminal, native_result=native_result,
                  last_monitor_frame=frames[-1]['frame'], observed_port_value_counts=counts,
                  first_observed_port_values=first, joystick_changes=joystick,
                  undecoded_cpu_io_reads=undecoded, paused_cpu_io_reads=paused_reads,
                  expected_nonzero_p1_values=sorted(expected), observed_nonzero_p1_values=sorted(actual),
                  all_scheduled_p1_values_observed=expected.issubset(actual),
                  coin_read=counts[2][128] > 0, start1_read=counts[2][4] > 0,
                  fire_read=counts[2][1] > 0, saved_frames=saved,
                  evidence_sha256={p.as_posix(): sha(p) for p in evidence},
                  limitations=['Hostile first partial field is retained; monitor frames are not rebased.',
                               'Input receipt alone does not prove scoring, deaths or complete lifecycle.',
                               'Moving wrapper RGB has no qualified MAME phase contract in this report.',
                               'Full audio, exact-source timing/resources and release remain separate gates.'],
                  mame_graphics_equivalence_qualified=False, complete_sheriff=False,
                  release_qualified=False, rbf_built=False)
    args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(report=args.output.as_posix(), last_monitor_frame=result['last_monitor_frame'],
                          all_scheduled_p1_values_observed=result['all_scheduled_p1_values_observed'],
                          coin_read=result['coin_read'], start1_read=result['start1_read'],
                          fire_read=result['fire_read'], complete_sheriff=False)))


if __name__ == '__main__':
    main()
