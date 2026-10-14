#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build and run the actual connected serializer through explicit Ubuntu WSL."""
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
    parser.add_argument('--attempt',help='Unique suffix preserving historical receipts/report.')
    args=parser.parse_args()
    if args.attempt:
        assert args.attempt.replace('-', '').isalnum()
    root=Path.cwd()
    suffix='-'+args.attempt if args.attempt else ''
    check=root/('_checks/video-path-20261010'+suffix)
    check.mkdir(exist_ok=False)
    files=[Path('rtl/n8080_video_path.sv'),Path('rtl/n8080_video_register.sv'),
           Path('sim/video_path.cpp'),Path(__file__)]
    before={p.as_posix():sha(p) for p in files}
    base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
    assert root.drive and root.is_absolute()
    linux_root='/mnt/'+root.drive[0].lower()+root.as_posix()[2:]
    model=linux_root+'/_checks/'+check.name+'/build'
    commands=[base+['verilator','--cc','--exe','--build','--top-module','n8080_video_path',
                    '--Mdir',model,'--threads','1','-j','2','-Wno-fatal',
                    'rtl/n8080_video_path.sv','rtl/n8080_video_register.sv',
                    linux_root+'/sim/video_path.cpp'],
              base+[model+'/Vn8080_video_path']]
    receipts=[]
    for label,command in zip(['build','test'],commands):
        start=datetime.now(timezone.utc).isoformat()
        run=subprocess.run(command,capture_output=True)
        (check/(label+'.stdout.log')).write_bytes(run.stdout)
        (check/(label+'.stderr.log')).write_bytes(run.stderr)
        receipt=dict(command=command,start_UTC=start,finish_UTC=datetime.now(timezone.utc).isoformat(),
                     exit_code=run.returncode,stdout=run.stdout.decode(errors='replace'),
                     stderr=run.stderr.decode(errors='replace'))
        (check/(label+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n')
        receipts.append(receipt)
        assert run.returncode==0,receipt
    assert receipts[1]['stdout'].strip()=='PASS byte_loads=512 stream_pixels=4096 post_edge_RD_holds=4096 blanked_boundaries=4'
    assert all(sha(p)==digest for p,digest in before.items())
    artifacts=[check/'build/Vn8080_video_path',*check.glob('*-receipt.json'),*check.glob('*.log')]
    report=dict(scope='Actual connected related-Bandido serializer gates and held-byte streams; not production raster/DRAM timing.',
                build_exit_code=0,test_exit_code=0,byte_loads=512,stream_pixels=4096,
                post_edge_RD_holds=4096,blanked_boundaries=4,
                receipts=receipts,source_changed_during_run=False,
                evidence_sha256={p.as_posix():sha(p) for p in [*files,*artifacts]},
                limitations=['Common counter CE/pre-edge phase supplied by bench; complete board address/blanking origin remains open.',
                             'Both source-connected OUT6 D5 directions checked; exact Sheriff revision and physical control-latch edge timing remain open.',
                             'Post-edge RD changes check byte retention, not electrical propagation/setup/hold or a fitted DRAM grade.',
                             'No source offset, actual game RAM patch, production board integration or MAME graphics waiver.'],
                connected_functional_path_qualified=True,integrated_in_board=False,
                physical_memory_timing_qualified=False,strict_graphics_gate_pass=False,
                quartus_executed=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_video_path'+suffix+'.json')
    output.write_text(json.dumps(report,indent=2)+'\n',newline='')
    print(json.dumps({k:report[k] for k in ['build_exit_code','test_exit_code','byte_loads','stream_pixels','post_edge_RD_holds','blanked_boundaries','integrated_in_board']}))


if __name__=='__main__':
    main()
