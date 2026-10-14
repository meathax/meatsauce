#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run the source-corrected native SN component in explicit Ubuntu WSL."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    check=Path('_checks/sn-pcm-quantization-20261010')
    check.mkdir(exist_ok=False)
    closure=[Path(p) for p in ['rtl/sheriff_sn76477.sv','rtl/sheriff_sn_constants.svh',
                             'tools/generate_sheriff_sn.py','sim/sn_qualification.cpp','sim/Makefile']]
    before={p.as_posix():sha(p) for p in closure}
    build='/mnt/d/Arcade/AI/aCORES/sherrif/_checks/sn-pcm-quantization-20261010/build'
    flags='-Wall -Wno-fatal --cc --exe --build -j 2 --threads 1 -I/mnt/d/Arcade/AI/aCORES/sherrif/rtl -CFLAGS "-O2 -std=c++17"'
    argv=['wsl.exe','-d','Ubuntu','--cd',str(Path.cwd()),'--exec','make','-C','sim','sn',
          f'BUILD={build}',f'VFLAGS={flags}','VERILATOR=/usr/local/bin/verilator']
    started=datetime.now(timezone.utc).isoformat()
    with (check/'stdout.log').open('wb') as out,(check/'stderr.log').open('wb') as err:
        code=subprocess.run(argv,stdout=out,stderr=err).returncode
    receipt=dict(exit_code=code,argv=argv,started_utc=started,
                 finished_utc=datetime.now(timezone.utc).isoformat(),source_sha256=before)
    (check/'exit.json').write_text(json.dumps(receipt,indent=2)+'\n')
    assert code==0
    assert before=={p.as_posix():sha(p) for p in closure}
    text=(check/'stdout.log').read_text()
    match=re.search(r'samples=(\d+) max_cap_error_V=([\deE.+-]+) noise_bit_errors=(\d+) vco_bit_errors=(\d+) pcm_rms_LSB=([\deE.+-]+) pcm_max_LSB=(\d+)',text)
    assert match is not None
    samples,capacitor,noise,vco,rms,peak=match.groups()
    assert int(samples)==96000 and int(noise)==int(vco)==0 and float(rms)==0 and int(peak)==0
    original=subprocess.check_output(['git','show','HEAD:rtl/sheriff_sn_constants.svh']).decode()
    current=Path('rtl/sheriff_sn_constants.svh').read_text()
    pattern=r"7'd(\d+): gain_sample = (-?)16'sd(\d+);"
    def words(source):
        return {int(i):int(v)*(-1 if sign else 1) for i,sign,v in re.findall(pattern,source)}
    old,new=words(original),words(current)
    assert len(old)==len(new)==90
    changed=[dict(address=i,old=old[i],new=new[i]) for i in new if new[i]!=old[i]]
    result=dict(scope='Native96000-sample SN capacitor/mode corpus with source-corrected float/PCM conversion.',
                receipt=receipt,samples=int(samples),maximum_capacitor_error_volts=float(capacitor),
                noise_comparator_mismatches=int(noise),vco_comparator_mismatches=int(vco),
                PCM_RMS_error=float(rms),PCM_max_error=int(peak),changed_gain_words=changed,
                added_registers=0,added_clock_domains=0,
                limitations=['Component corpus is not current full-gameplay audio or final integrated source qualification.',
                             'Q32 capacitor gain-boundary arithmetic remains unchanged; no fitted bias or delay.',
                             'DAC resampling and final mixed-stream quantization remain separate.',
                             'Exact-source fit/timing/resources remain unverified pending shared-queue admission.'],
                evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__),*closure,
                    check/'exit.json',check/'stdout.log',check/'stderr.log',
                    check/'build/sn/Vsheriff_sn76477',check/'build/sn/qualification.csv',
                    Path('D:/Arcade/AI/mame289/src/devices/sound/sn76477.cpp'),
                    Path('D:/Arcade/AI/mame289/src/emu/sound.cpp')]},
                whole_sound_gate_pass=False,release_qualified=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_sn_pcm_quantization.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),exit_code=code,samples=int(samples),
                         PCM_RMS_error=float(rms),changed_gain_words=len(changed),whole_sound_gate_pass=False)))


if __name__=='__main__':
    main()
