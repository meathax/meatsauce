#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bind the first SN residual gain boundary to frozen native/reference data.

This computes an applicable arithmetic cause, without claiming direct live
capacitor-state observation or modifying RTL to fit a waveform.
"""
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    diagnostic_path = Path('docs/evidence/sheriff_dac_waveform_origin.json')
    diagnostic = json.loads(diagnostic_path.read_text())
    difference = diagnostic['first_SN_residual_difference_exceeding1LSB']
    target = difference['sample']
    paths = [Path('sim/results/current-gameplay-1201-rtl-20261010/io.csv'),
             Path('sim/results/current-sound-precision-1201-mame-20261010/io.csv')]
    triggers = []
    for path in paths:
        previous, selected = 0, None
        for row in csv.DictReader(path.open()):
            if row['kind'] != 'out' or int(row['address']) % 256 != 4:
                continue
            data = int(row['data'])
            rising = (~previous) & data & 0x14
            previous = data
            if not rising:
                continue
            if 'tick' in row:
                # Native PCM index n is emitted at tick1049+1050*n.
                start = int(row['tick']) // 1050
            else:
                # MAME generates through floor(t*rate)+1 before enable_w.
                start = int(Decimal(row['time']) * 48000) + 1
            if start <= target:
                selected = dict(row=row, trigger_bits=rising, first_new_sample=start)
        assert selected is not None and selected['trigger_bits'] == 16
        triggers.append(selected)
    assert triggers[0]['first_new_sample'] == triggers[1]['first_new_sample'] == 780386
    updates = target - triggers[0]['first_new_sample'] + 1
    assert updates == 800
    constants = Path('rtl/sheriff_sn_constants.svh')
    text = constants.read_text()
    up = int(re.search(r"AD_UP\s*=\s*36'd(\d+)", text)[1])
    step = 4.44 / (20e3 * 1e-6) / 48000
    voltage = 0.0
    for _ in range(updates):
        voltage += step
    floating_index, fixed_index = int(voltage * 10), updates * up * 10 // 2**32
    assert (floating_index, fixed_index) == (36, 37)
    negative = {int(index): -int(value) for index, value in
                re.findall(r"7'd(\d+): gain_sample = -16'sd(\d+);", text)}
    assert negative[fixed_index] == difference['native_SN'] == -5231
    result = dict(scope='First larger SN PCM residual difference: source-derived gain-boundary arithmetic.',
                  first_difference=difference, command_triggers=triggers, charge_updates=updates,
                  charging_step_double=step, voltage_double=voltage, gain_index_double=floating_index,
                  AD_UP_Q32=up, voltage_Q32=updates*up/2**32, gain_index_Q32=fixed_index,
                  current_negative_gain_entries={str(i):negative[i] for i in (floating_index, fixed_index)},
                  direct_live_capacitor_state_observed=False,
                  limitations=['Enable sample indices are derived from frozen I/O and documented stream/harness ordering.',
                               'Native latch/monostable propagation is shorter than the remaining distance to its next audio sample.',
                               'Calculated floating capacitor value is not a private live MAME state capture.',
                               'This boundary explains an applicable152LSB discrepancy; later oscillator/noise and mixed-waveform differences remain open.',
                               'No upstream MAME bug report is asserted; this is local numerical comparison evidence.'],
                  evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__),diagnostic_path,constants,*paths,
                      Path('rtl/n8080_mcs48.sv'), Path('rtl/sheriff_sn76477.sv'),
                      Path('D:/Arcade/AI/mame289/src/devices/sound/sn76477.cpp'),
                      Path('D:/Arcade/AI/mame289/src/emu/sound.cpp')]},
                  fitted_parameters=False, rtl_changed=False, whole_sound_gate_pass=False, release_qualified=False)
    output = Path('docs/evidence/sheriff_sn_gain_boundary.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),sample=target,updates=updates,
                         floating_voltage=voltage,fixed_voltage=result['voltage_Q32'],
                         floating_index=floating_index,fixed_index=fixed_index,whole_sound_gate_pass=False)))


if __name__ == '__main__':
    main()
