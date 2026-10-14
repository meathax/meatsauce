#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Native qualification of joined horizontal/phase/serializer blocks."""
from datetime import datetime,timezone
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--attempt',help='Fresh receipt subdirectory while preserving earlier failed attempts.')
    parser.add_argument('--reuse-build',action='store_true',help='Rebuild changed C++ only with the retained generated RTL model.')
    args=parser.parse_args()
    assert not args.reuse_build or args.attempt
    root=Path.cwd();base_check=root/'_checks/horizontal-video-path-20261010'
    check=base_check/('attempt-'+args.attempt) if args.attempt else base_check
    check.mkdir(exist_ok=False)
    top=check/'horizontal_video_path_qualification.sv'
    top.write_text('''module horizontal_video_path_qualification(
input wire clk,reset,ce_xtal,ce_counter,vb,flip_latched,
input wire [7:0] rd,
output wire [3:0] phase_4i,upper_4j,
output wire hb,raw_cas_n,hread_n,video_bit,load_mode,
output wire [7:0] register_q);
wire active;
n8080_memory_phases phases(.clk(clk),.reset(reset),.ce_xtal(ce_xtal),
.raw_cas_n(raw_cas_n),.raw_ras_n(),.comadr_n(),.hread_n(hread_n),.phase_4i(phase_4i),.delay_4a());
n8080_horizontal_counter horizontal(.clk(clk),.reset(reset),.ce_counter(ce_counter),
.phase_4i(phase_4i),.upper_4j(upper_4j),.h_active(active),.hb(hb),.terminal_carry());
n8080_video_path path(.clk(clk),.ce_counter(ce_counter),.clear_n(!reset),
.phase_4i(phase_4i[2:0]),.hb(hb),.vb(vb),.flip_latched(flip_latched),
.serial_right(1'b0),.serial_left(1'b0),.rd(rd),.video_bit(video_bit),.load_mode(load_mode),.register_q(register_q));
endmodule
''')
    files=[Path('rtl/n8080_memory_phases.sv'),Path('rtl/n8080_horizontal_counter.sv'),
           Path('rtl/n8080_video_register.sv'),Path('rtl/n8080_video_path.sv'),
           Path('sim/horizontal_video_path.cpp'),Path(__file__),top]
    sources={p.as_posix():sha(p) for p in files}
    base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
    linux='/mnt/d/Arcade/AI/aCORES/sherrif'
    build=linux+'/_checks/horizontal-video-path-20261010/build'
    if args.reuse_build:
        assert top.read_bytes()==(base_check/'horizontal_video_path_qualification.sv').read_bytes()
        assert (base_check/'build/Vhorizontal_video_path_qualification.mk').exists()
    commands=[base+['verilator','--cc','--exe','--build','--top-module','horizontal_video_path_qualification',
                    '--Mdir',build,'--threads','1','-j','2','-Wno-fatal',
                    linux+'/_checks/horizontal-video-path-20261010/horizontal_video_path_qualification.sv',
                    *[p.as_posix() for p in files[:4]],linux+'/sim/horizontal_video_path.cpp'],
              base+[build+'/Vhorizontal_video_path_qualification']]
    if args.reuse_build:
        commands[0]=base+['make','-C',build,'-f','Vhorizontal_video_path_qualification.mk','-j','2']
    receipts=[]
    for name,command in zip(['build','test'],commands):
        start=datetime.now(timezone.utc).isoformat();run=subprocess.run(command,capture_output=True)
        (check/(name+'.stdout.log')).write_bytes(run.stdout);(check/(name+'.stderr.log')).write_bytes(run.stderr)
        receipt=dict(command=command,start_UTC=start,finish_UTC=datetime.now(timezone.utc).isoformat(),exit_code=run.returncode,
                     stdout=run.stdout.decode(errors='replace'),stderr=run.stderr.decode(errors='replace'))
        (check/(name+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n');receipts.append(receipt)
        assert run.returncode==0,receipt
    assert receipts[1]['stdout'].strip()=='PASS counter_pixels=1280 active_pixels=1024 blank_pixels=256 byte_loads=128 RD_retention_observations=5120 first_byte_after_active_clocks=8'
    assert all(sha(p)==digest for p,digest in sources.items())
    artifacts=[base_check/'build/Vhorizontal_video_path_qualification',*check.glob('*-receipt.json'),*check.glob('*.log')]
    report=dict(scope='Joined related-Bandido horizontal reload, actual phase generator and corrected blanking-polarity serializer; isolated native functional model.',
                build_exit_code=0,test_exit_code=0,counter_period_pixels=320,active_pixels_per_period=256,blank_pixels_per_period=64,
                tested_counter_pixels=1280,byte_loads=128,RD_retention_observations=5120,
                first_byte_after_active_counter_clocks=8,receipts=receipts,
                generated_RTL_model_reused=args.reuse_build,
                evidence_sha256={p.as_posix():sha(p) for p in [*files,*artifacts]},
                source_changed_during_run=False,
                limitations=['Reproducible reset origin and zero-delay RCO/inverter/4G ordering; C5/gate/enable electrical timing is not qualified.',
                             'Counter and byte-stream pipeline are observed; analog visible window and final PROM/RGB gating still require derivation.',
                             'RD is driven from phase-derived video CAS with a three-crystal functional data latency; this is not a physical DRAM grade or full controller.',
                             'Complementary NOR/REV streams tested; related-board OUT6 D5 mapping is recorded in sheriff_video_flip.json; exact Sheriff revision remains open.',
                             'No production board integration, raster/reference shift, ROM/state patch or graphics failure waiver.'],
                integrated_in_board=False,physical_memory_timing_qualified=False,strict_graphics_gate_pass=False,
                quartus_executed=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_horizontal_video_path.json');output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['build_exit_code','test_exit_code','counter_period_pixels','active_pixels_per_period','blank_pixels_per_period','tested_counter_pixels','byte_loads','first_byte_after_active_counter_clocks','integrated_in_board']}))


if __name__=='__main__':
    main()
