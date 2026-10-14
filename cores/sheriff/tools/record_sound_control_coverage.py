#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Locate actual mono0/mono1/overlap cases in existing Sheriff gameplay writes."""
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect(path):
    duration = Decimal('0.59895')
    ends = [Decimal(0), Decimal(0)]
    counts = {'mono0_triggers': 0, 'mono1_triggers': 0,
              'mono0_retriggers': 0, 'mono1_retriggers': 0,
              'mono0_cancels_mono1': 0, 'mono1_overlaps_mono0': 0,
              'simultaneous_triggers': 0}
    first = {}
    previous, rows, last_time = 0, 0, Decimal(0)
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream)
        native = 'tick' in reader.fieldnames
        for row in reader:
            rows += 1
            time = Decimal(row['tick']) / Decimal(50400000) if native else Decimal(row['time'])
            assert time >= last_time, (path, rows)
            last_time = time
            if row['kind'] != 'out' or int(row['address']) & 7 != 4:
                continue
            data = int(row['data'])
            rising = data & ~previous & 0x14
            previous = data
            if not rising:
                continue
            labels = []
            if rising & 4:
                labels.append('mono0_triggers')
                if ends[0] > time:
                    labels.append('mono0_retriggers')
                if ends[1] > time:
                    labels.append('mono0_cancels_mono1')
                ends[0], ends[1] = time + duration, Decimal(0)
            if rising & 16:
                labels.append('mono1_triggers')
                if ends[1] > time:
                    labels.append('mono1_retriggers')
                if ends[0] > time:
                    labels.append('mono1_overlaps_mono0')
                ends[1] = time + duration
            if rising == 0x14:
                labels.append('simultaneous_triggers')
            for label in labels:
                counts[label] += 1
                first.setdefault(label, {'time': str(time), 'row': row})
    return {'path': path.as_posix(), 'sha256': sha(path), 'rows': rows,
            'native_tick_source': native, 'last_time': str(last_time),
            'counts': counts, 'first_occurrences': first}


def main():
    paths = [Path('sim/results')/name/'io.csv' for name in [
        'current-gameplay-1201-rtl-20261010',
        'current-cocktail-4801-rtl-20261010',
        'rounds-three-mame',
    ]]
    captures = [inspect(path) for path in paths]
    assert captures[0]['counts']['mono1_triggers'] == 5
    assert captures[0]['counts']['mono0_triggers'] == 0
    report = {
        'scope': 'Coverage inventory of recorded real gameplay output writes; not SN waveform or complete gameplay qualification.',
        'equations': 'Rising sound1 bit2 falls pins[6] and starts mono0, cancelling mono1; rising bit4 falls pins[4] and starts mono1. Both nominal durations 0.59895s. Apply mono0 before mono1 for simultaneous writes.',
        'captures': captures,
        'source_sha256': {p.as_posix(): sha(p) for p in [Path(__file__), Path('rtl/n8080_mcs48.sv')]},
        'limits': ['Decimal timestamps and nominal durations locate test cases; they do not qualify sample-edge scheduling.',
                   'Existing native captures predate the current gain conversion; source/receipt binding is required before replay qualification.',
                   'No native or MAME rerun, no waveform pass and no whole-audio pass.'],
        'whole_audio_gate_pass': False,
    }
    out = Path('docs/evidence/sheriff_sound_control_coverage.json')
    out.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'report': out.as_posix(), 'coverage': [
        {'path': c['path'], **c['counts']} for c in captures]}))


if __name__ == '__main__':
    main()
