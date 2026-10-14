#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Record completed chip data honestly when the original OS receipt was lost."""
import array
import argparse
import csv
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import wave
from diagnose_dac_waveform_origin import coefficients,events,project_dac,stats


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def pcm(path):
    result=array.array('h');result.frombytes(path.read_bytes());return result


def bind_completion():
    check=Path('_checks/sn-gameplay-replay-20261010')
    output=Path('docs/evidence/sheriff_sn_gameplay_replay.json')
    result=json.loads(output.read_text())
    backup=check/'data-only-report.json'
    assert not backup.exists()
    backup.write_bytes(output.read_bytes())
    binding=json.loads((check/'source-binding-v3.json').read_text())
    for path,digest in binding['evidence_sha256'].items():
        assert sha(path)==digest
    terminal=json.loads((check/'terminal-v3.json').read_text())
    assert terminal['exit_code']==0 and not terminal['source_changed_during_run']
    for name in ['old-sn.raw','current-sn.raw','capacitor_window.csv']:
        assert sha(check/'run-v3'/name)==sha(check/'run'/name)
    result.update(scope='Receipt-backed native SN chip replay of saved real8080 writes;937008 samples.',
                  completed_native_receipt=terminal,completed_case_source_binding=binding,
                  completed_case_outputs_identical_to_initial_data=True,
                  native_replay_driver_qualified=True,current_replayed_chip_case_completed=True)
    result['limitations']=[line for line in result['limitations'] if not line.startswith('Recorded chip data is diagnostic evidence;')]
    result['limitations'].insert(0,'Completed v3 native case has actual exit0; original missing exit and v2 pre-start WSL failure remain retained.')
    result['evidence_sha256'].update({p.as_posix():sha(p) for p in [Path(__file__),backup,
        check/'source-binding-v3.json',check/'terminal-v3.json',check/'WSL-probe.json']})
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),native_exit_code=0,samples=937008,
                         old_identity_differences=0,current_residual=result['current_SN_vs_reference_residual'],
                         whole_sound_gate_pass=False)))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind-completion',action='store_true')
    args=parser.parse_args()
    if args.bind_completion:
        bind_completion()
        return
    check=Path('_checks/sn-gameplay-replay-20261010')
    launch=json.loads((check/'launch.json').read_text())
    assert all(sha(p)==v for p,v in launch['source_sha256'].items())
    assert json.loads((check/'build-exit.json').read_text())['exit_code']==0
    run=check/'run'
    native=json.loads((run/'native-result.json').read_text())
    assert native['samples']==937008 and native['old_identity_differences']==0
    old,current,expected=map(pcm,[run/'old-sn.raw',run/'current-sn.raw',check/'old-expected-sn.raw'])
    assert old==expected and len(current)==len(old)==937008
    capture=Path('sim/results/current-sound-precision-1201-mame-20261010')
    precision=json.loads(Path('_checks/sound-pin-precision-20261010/terminal.json').read_text())
    assert precision['receipt']['exit_code']==0 and all(precision['observer_unchanged'].values())
    pins=capture/'sound_pins.csv'
    assert sha(pins)==precision['evidence_sha256'][pins.resolve().as_posix()]
    with wave.open(str(capture/'audio.wav')) as wav:
        reference=array.array('h');reference.frombytes(wav.readframes(wav.getnframes()))
    count=min(len(reference),len(current))
    dac=project_dac(events(pins,False),count,coefficients())
    residual=array.array('h',(reference[i]-int(dac[i]*32768) for i in range(count)))
    def first(predicate):
        i=next((i for i in range(count) if predicate(current[i],residual[i])),None)
        return None if i is None else dict(sample=i,current_SN=int(current[i]),reference_PCM_residual=int(residual[i]))
    shape=first(lambda a,b:abs(a-b)>1000)
    assert shape is not None
    frozen=Path('sim/results/current-gameplay-1201-rtl-20261010/io.csv')
    outs=[];previous=0
    for row in csv.DictReader(frozen.open()):
        if row['kind']=='out' and int(row['address'])%8==4:
            data=int(row['data']);rising=(~previous)&data&0x14;previous=data
            if rising:outs.append(dict(row=row,trigger_bits=rising))
    tick=1049+1050*shape['sample']
    recent=[r for r in outs if 0<=tick-int(r['row']['tick'])<50400000]
    rows=list(csv.DictReader((run/'capacitor_window.csv').open()))
    boundary=next(r for r in rows if int(r['sample'])==781185)
    assert int(boundary['ad_Q32'])==15891379200
    v2=json.loads((check/'terminal-v2.json').read_text())
    artifacts=[Path(__file__),Path('sim/sn_gameplay_replay.cpp'),Path('tools/run_sn_gameplay_replay.py'),
               *[Path(p) for p in launch['source_sha256']],check/'build-exit.json',check/'build.log',
               check/'launch.json',check/'launch-v2.json',check/'terminal-v2.json',check/'stdout-v2.log',
               check/'old_sheriff_sn76477.sv',check/'old_sn_constants.svh',check/'sn_gameplay_replay.sv',
               check/'old-expected-sn.raw',run/'native-result.json',run/'old-sn.raw',run/'current-sn.raw',
               run/'capacitor_window.csv',check/'build/Vsn_gameplay_replay',capture/'audio.wav',pins,frozen]
    result=dict(scope='Completed native SN chip replay data from actual saved8080 writes; original OS exit receipt unavailable.',
                build_exit_code=0,original_launch=launch,native_data=native,
                original_OS_exit_code=None,original_process_confirmed_missing=True,
                second_attempt=v2,second_attempt_entered_native_simulation=False,
                WSL_error='Wsl/Service/0x8007274c connection timeout before native start.',
                old_data_exact_identity=True,changed_current_samples=sum(a!=b for a,b in zip(old,current)),
                before_SN_reference_DAC_samples=780617,
                old_SN_vs_reference_residual=stats(old,residual,count),
                current_SN_vs_reference_residual=stats(current,residual,count),
                first_current_difference_exceeding1LSB=first(lambda a,b:abs(a-b)>1),
                first_shape_difference_exceeding1000LSB=shape,
                first_opposite_sign=first(lambda a,b:a*b<0),
                first_suppressed_or_unsuppressed=first(lambda a,b:(a==0)!=(b==0) and abs(a-b)>1),
                recent_main_sound_triggers=recent,actual_native_gain_boundary=boundary,
                actual_boundary_voltage=int(boundary['ad_Q32'])/2**32,
                actual_boundary_gain_index=int(boundary['ad_Q32'])*10//2**32,
                limitations=['Recorded chip data is diagnostic evidence; missing original OS exit prevents a complete native-run gate.',
                             'Original native process handle was confirmed missing; no repeat was started solely on an observation failure.',
                             'Second attempt failed before Linux execution; original completed data and all failure receipts retained.',
                             'Driver uses recorded actual CPU outputs and verbatim monostable RTL, not current full CPU/gameplay execution.',
                             'Reference PCM residual subtracts quantized DAC reconstruction; mixer rounding can contribute1LSB.',
                             'A1000LSB locator is diagnostic only, not an acceptance tolerance or exclusion of earlier differences.',
                             'Current full-board audio, physical timing, fit/resources and release remain open.'],
                evidence_sha256={p.as_posix():sha(p) for p in artifacts},
                full_native_chip_gate_pass=False,whole_sound_gate_pass=False,release_qualified=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_sn_gameplay_replay.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),old_identity=True,current_SN=result['current_SN_vs_reference_residual'],
                         gain_boundary_voltage=result['actual_boundary_voltage'],gain_boundary_index=result['actual_boundary_gain_index'],
                         first_shape=shape,recent_triggers=recent,full_native_chip_gate_pass=False)))


if __name__=='__main__':
    main()
