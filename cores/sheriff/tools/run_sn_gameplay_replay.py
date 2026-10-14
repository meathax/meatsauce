#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Qualify chip replay against actual original board audio before trusting it."""
import array
import argparse
import csv
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def write(path,value):
    path.write_text(json.dumps(value,indent=2)+'\n')


def reuse_build(attempt):
    check=Path('_checks/sn-gameplay-replay-20261010')
    first=json.loads((check/'launch.json').read_text())
    before=first['source_sha256']
    assert all(sha(p)==digest for p,digest in before.items())
    assert json.loads((check/'build-exit.json').read_text())['exit_code']==0
    run=list(first['argv'])
    run[-1]=run[-1].rsplit('/',1)[0]+'/run-'+attempt
    assert not (check/('run-'+attempt)).exists()
    assert not (check/('terminal-'+attempt+'.json')).exists()
    binary=check/'build/Vsn_gameplay_replay'
    binary_hash=sha(binary)
    start=datetime.now(timezone.utc).isoformat()
    with (check/('stdout-'+attempt+'.log')).open('wb') as out,(check/('stderr-'+attempt+'.log')).open('wb') as err:
        process=subprocess.Popen(run,stdout=out,stderr=err)
        write(check/('launch-'+attempt+'.json'),dict(pid=process.pid,started_utc=start,argv=run,
              source_sha256=before,model_sha256=binary_hash))
        code=process.wait()
    changed=[p for p,digest in before.items() if sha(p)!=digest]
    assert sha(binary)==binary_hash
    terminal=dict(exit_code=code,started_utc=start,finished_utc=datetime.now(timezone.utc).isoformat(),
                  source_changed_during_run=changed,scope='SN chip replay, not current full-board gameplay.')
    write(check/('terminal-'+attempt+'.json'),terminal)
    if code!=0:
        raise SystemExit(code)
    result=json.loads((check/('run-'+attempt)/'native-result.json').read_text())
    assert code==0 and not changed and result['old_identity_differences']==0
    original=Path('_checks/current-gameplay-1201-20261010/terminal.json')
    receipt=json.loads(original.read_text(encoding='utf-8-sig'))
    native=Path(receipt['runtime_output'])
    write(check/('source-binding-'+attempt+'.json'),dict(original_receipt=receipt,source_sha256=before,
          evidence_sha256={p.as_posix():sha(p) for p in [original,native/'io.csv',native/'sound.csv',native/'audio.raw',
              check/'old_sheriff_sn76477.sv',check/'old_sn_constants.svh',check/'sn_gameplay_replay.sv',
              check/'old-expected-sn.raw',check/'build-exit.json',check/'build.log',check/('launch-'+attempt+'.json'),
              check/('terminal-'+attempt+'.json'),check/('stdout-'+attempt+'.log'),check/('stderr-'+attempt+'.log'),
              check/('run-'+attempt)/'native-result.json',check/('run-'+attempt)/'old-sn.raw',
              check/('run-'+attempt)/'current-sn.raw',check/('run-'+attempt)/'capacitor_window.csv',
              binary,Path(__file__),Path('sim/sn_gameplay_replay.cpp')]}))
    print(json.dumps(dict(terminal=terminal,native=result)))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reuse-build',action='store_true')
    parser.add_argument('--attempt',choices=['v2','v3'],default='v2')
    args=parser.parse_args()
    if args.reuse_build:
        reuse_build(args.attempt)
        return
    project=Path.cwd()
    check=Path('_checks/sn-gameplay-replay-20261010')
    check.mkdir(exist_ok=False)
    original=Path('_checks/current-gameplay-1201-20261010/terminal.json')
    receipt=json.loads(original.read_text(encoding='utf-8-sig'))
    assert receipt['exit_code']==0 and not receipt['source_changed_during_run']
    native=Path(receipt['runtime_output'])
    old_constants=subprocess.check_output(['git','show','a5dd5bb:rtl/sheriff_sn_constants.svh'])
    assert hashlib.sha256(old_constants).hexdigest()==receipt['source_sha256']['rtl/sheriff_sn_constants.svh']
    sources=[Path('rtl/sheriff_sn76477.sv'),Path('rtl/n8080_board.sv'),Path('rtl/n8080_mcs48.sv')]
    for p in sources:
        assert sha(p)==receipt['source_sha256'][p.as_posix()]
    before={p.as_posix():sha(p) for p in [*sources,Path('rtl/sheriff_sn_constants.svh'),Path('sim/sn_gameplay_replay.cpp')]}
    (check/'old_sn_constants.svh').write_bytes(old_constants)
    old_source=sources[0].read_text().replace('module sheriff_sn76477','module old_sheriff_sn76477',1)
    old_source=old_source.replace('"sheriff_sn_constants.svh"','"old_sn_constants.svh"',1)
    (check/'old_sheriff_sn76477.sv').write_text(old_source)
    mono=sources[2].read_text().split("    reg [12:0] previous_pins=",1)[1].rsplit('endmodule',1)[0]
    mono="    reg [12:0] previous_pins="+mono
    top='''// SPDX-License-Identifier: GPL-2.0-or-later
module sn_gameplay_replay(input wire clk,reset,write,input wire[2:0]port,input wire[7:0]data,
 output wire old_ce,current_ce, output wire signed[15:0]old_pcm,current_pcm,
 output wire[35:0]old_ad,current_ad,old_vco,current_vco,old_noise,current_noise,old_slf,current_slf,
 output wire enabled,mode,mixer,voltage5,output wire[35:0]current_shot,
 output wire current_shot_running,current_filter,current_vco_bit);
 reg[7:0]sound1=0,sound2=0;
 always @(posedge clk) if(reset)begin sound1<=0;sound2<=0;end
 else if(write)case(port)4:sound1<=data;5:sound2<=data;default:begin end endcase
 wire pause=0,mono0,mono1,sn_enable,sn_vco_mode,sn_mixer_b,sn_vco_5v;
 wire[12:0]pins={~sound2[5],~sound2[3],~sound2[2],~sound2[1],~sound2[0],
                ~sound1[0],~sound1[2],~sound1[1],~sound1[4],~sound1[3],~sound2[4],~sound1[5],1'b0};
'''+mono+'''
 assign enabled=sn_enable;assign mode=sn_vco_mode;assign mixer=sn_mixer_b;assign voltage5=sn_vco_5v;
 old_sheriff_sn76477 old_chip(.clk(clk),.reset(reset),.pause(pause),.enabled(sn_enable),
 .vco_mode(sn_vco_mode),.mixer_b(sn_mixer_b),.vco_5v(sn_vco_5v),.sample_ce(old_ce),.sample(old_pcm),
 .ad_voltage(old_ad),.vco_voltage(old_vco),.noise_voltage(old_noise),.slf_voltage(old_slf),
 .slf_bit(),.vco_bit(),.filtered_noise());
 sheriff_sn76477 current_chip(.clk(clk),.reset(reset),.pause(pause),.enabled(sn_enable),
 .vco_mode(sn_vco_mode),.mixer_b(sn_mixer_b),.vco_5v(sn_vco_5v),.sample_ce(current_ce),.sample(current_pcm),
 .ad_voltage(current_ad),.vco_voltage(current_vco),.noise_voltage(current_noise),.slf_voltage(current_slf),
 .slf_bit(),.vco_bit(current_vco_bit),.filtered_noise(current_filter));
 assign current_shot=current_chip.shot_voltage;assign current_shot_running=current_chip.shot_running;
 endmodule
'''
    (check/'sn_gameplay_replay.sv').write_text(top)
    raw=array.array('h');raw.frombytes((native/'audio.raw').read_bytes())
    pins=[(int(r['tick']),int(r['dac'])) for r in csv.DictReader((native/'sound.csv').open())]
    old_sn=array.array('h');j=0;dac=1
    for i,value in enumerate(raw):
        tick=1049+1050*i
        while j<len(pins) and pins[j][0]<=tick:
            dac=pins[j][1];j+=1
        old_sn.append(value-(4915 if dac else 0))
    (check/'old-expected-sn.raw').write_bytes(old_sn.tobytes())
    linux='/mnt/d/Arcade/AI/aCORES/sherrif/'
    build=linux+check.as_posix()+'/build'
    argv=['wsl.exe','-d','Ubuntu','--cd',str(project),'--exec','/usr/local/bin/verilator',
          '-Wall','-Wno-fatal','--cc','--exe','--build','-j','2','--threads','1',
          '--top-module','sn_gameplay_replay','--Mdir',build,'-I'+linux+'rtl','-I'+linux+check.as_posix(),
          '-CFLAGS','-O2 -std=c++17',linux+check.as_posix()+'/sn_gameplay_replay.sv',
          linux+check.as_posix()+'/old_sheriff_sn76477.sv',linux+'rtl/sheriff_sn76477.sv',linux+'sim/sn_gameplay_replay.cpp']
    start=datetime.now(timezone.utc).isoformat()
    with (check/'build.log').open('wb') as out:
        code=subprocess.run(argv,stdout=out,stderr=subprocess.STDOUT).returncode
    write(check/'build-exit.json',dict(exit_code=code,argv=argv,started_utc=start,finished_utc=datetime.now(timezone.utc).isoformat()))
    assert code==0
    run=['wsl.exe','-d','Ubuntu','--cd',str(project),'--exec',build+'/Vsn_gameplay_replay',
         linux+native.as_posix()+'/io.csv',linux+check.as_posix()+'/old-expected-sn.raw',linux+check.as_posix()+'/run']
    start=datetime.now(timezone.utc).isoformat()
    with (check/'stdout.log').open('wb') as out,(check/'stderr.log').open('wb') as err:
        process=subprocess.Popen(run,stdout=out,stderr=err)
        write(check/'launch.json',dict(pid=process.pid,started_utc=start,argv=run,source_sha256=before))
        code=process.wait()
    changed=[p for p,digest in before.items() if sha(p)!=digest]
    terminal=dict(exit_code=code,started_utc=start,finished_utc=datetime.now(timezone.utc).isoformat(),
                  source_changed_during_run=changed,scope='SN chip replay, not current full-board gameplay.')
    write(check/'terminal.json',terminal)
    result=json.loads((check/'run/native-result.json').read_text())
    assert code==0 and not changed and result['old_identity_differences']==0
    write(check/'source-binding.json',dict(original_receipt=receipt,source_sha256=before,
          evidence_sha256={p.as_posix():sha(p) for p in [original,native/'io.csv',native/'sound.csv',native/'audio.raw',
              check/'old_sheriff_sn76477.sv',check/'old_sn_constants.svh',check/'sn_gameplay_replay.sv',
              check/'old-expected-sn.raw',check/'build-exit.json',check/'build.log',check/'launch.json',
              check/'terminal.json',check/'stdout.log',check/'stderr.log',check/'run/native-result.json',
              check/'run/old-sn.raw',check/'run/current-sn.raw',check/'run/capacitor_window.csv',
              check/'build/Vsn_gameplay_replay',Path(__file__),Path('sim/sn_gameplay_replay.cpp')]}))
    print(json.dumps(dict(terminal=terminal,native=result)))


if __name__=='__main__':
    main()
