#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Source-derived trigger/expiry sample positions, without shifting audio."""
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def triggers(path):
    result=[];previous=0
    for row in csv.DictReader(path.open()):
        if row['kind']=='out' and int(row['address'])%8==4:
            data=int(row['data']);rising=(~previous)&data&0x14;previous=data
            if rising:result.append(dict(row=row,trigger_bits=rising))
    return result


def main():
    native=Path('sim/results/current-gameplay-1201-rtl-20261010/io.csv')
    reference=Path('sim/results/current-sound-precision-1201-mame-20261010/io.csv')
    n,m=triggers(native),triggers(reference)
    assert [r['trigger_bits'] for r in n]==[r['trigger_bits'] for r in m]
    assert n[0]['trigger_bits']==n[1]['trigger_bits']==16
    pairs=[]
    for a,b in zip(n[:2],m[:2]):
        tick=int(a['row']['tick']);time=Decimal(b['row']['time'])
        # Board writes sound1 at recorded pre-edge tick. The verbatim
        # monostable consumes changed pins on the following edge. SN
        # samples old flags on that same edge, hence strictly later CE.
        native_start=tick+1;native_expire=native_start+30187080
        reference_expire=time+Decimal('0.59895')
        pairs.append(dict(native=a,reference=b,
            source_predicted_native_start_sample=(native_start+1)//1050,
            source_predicted_reference_start_sample=int(time*48000)+1,
            source_predicted_native_expiry_sample=(native_expire+1)//1050,
            source_predicted_reference_expiry_sample=int(reference_expire*48000)+1,
            native_expiry_tick=native_expire,reference_expiry_seconds=str(reference_expire),
            reference_start_distance_to_previous_sample_seconds=str(time-Decimal(int(time*48000))/48000)))
    source=[Path(p) for p in ['rtl/n8080_board.sv','rtl/n8080_mcs48.sv','rtl/sheriff_sn76477.sv',
              'sim/board_harness.cpp','D:/Arcade/AI/mame289/src/mame/nintendo/n8080_a.cpp',
              'D:/Arcade/AI/mame289/src/emu/sound.cpp']]
    result=dict(scope='First two mono1 bursts: source-derived control sampling positions, not private live MAME SN-pin timestamps.',
                sample_rate_hz=48000,master_clock_hz=50400000,native_mono_ticks=30187080,
                reference_mono_seconds='0.59895',first_two_bursts=pairs,
                native_sample_tick='1049+1050*n',reference_update_rule='Generate old source through floor(time*rate), then change the value.',
                fitted_parameters=False,sample_offset_applied=0,audio_unchanged=True,
                limitations=['Native sequence is derived from registered board latches and verbatim monostable RTL.',
                             'MAME prediction uses captured CPU I/O times and direct sound1_w/pins_changed handlers; exact private timer/stream state is not independently captured.',
                             'Decimal12-place I/O times are retained; no rounding bias or timestamp shift is introduced.',
                             'Predicted sample differences identify a falsifiable sampling/oscillator-phase mechanism, not complete waveform causation.',
                             'No hardware control delay, gain bias or acceptance tolerance is authorized by this diagnostic.'],
                evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__),native,reference,*source]},
                whole_sound_gate_pass=False,release_qualified=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_sn_control_sampling.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),first_two_bursts=pairs,whole_sound_gate_pass=False)))


if __name__=='__main__':
    main()
