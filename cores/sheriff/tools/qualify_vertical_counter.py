#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Receipt-backed native qualification of related-board raster counters only."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess

ROOT=Path(__file__).resolve().parents[1]
CHECK=ROOT/'_checks/vertical-counter-20261010'
SOURCE=['rtl/n8080_horizontal_counter.sv','rtl/n8080_vertical_counter.sv',
        'sim/raster_counter_qualification.sv','sim/raster_counter_qualification.cpp']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def linux(p):
    s=p.resolve().as_posix();return '/mnt/'+s[0].lower()+s[2:]
def main():
    CHECK.mkdir(exist_ok=True)
    assert not (CHECK/'build-receipt.json').exists(),'Retain existing attempt; do not rerun unchanged'
    hashes={s:sha(ROOT/s) for s in SOURCE}
    base=['wsl.exe','-d','Ubuntu','--cd',str(ROOT),'--exec']
    build=linux(CHECK/'build')
    commands=[base+['verilator','--cc','--exe','--build','--top-module','raster_counter_qualification',
                   '--Mdir',build,'--assert','--timing','--threads','1','--x-initial','unique',
                   '--x-assign','unique','-j','2','-Wno-fatal','-CFLAGS','-O2 -std=c++17',
                   *[linux(ROOT/s) for s in SOURCE]],
              base+[build+'/Vraster_counter_qualification','+verilator+seed+1']]
    receipts=[]
    for name,cmd in zip(['build','test'],commands):
        start=datetime.now(timezone.utc).isoformat()
        r=subprocess.run(cmd,capture_output=True)
        receipt={'command':cmd,'started_utc':start,'finished_utc':datetime.now(timezone.utc).isoformat(),
                 'exit_code':r.returncode,'stdout':r.stdout.decode(errors='replace'),
                 'stderr':r.stderr.decode(errors='replace'),'source_sha256':hashes}
        (CHECK/(name+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8',newline='')
        receipts.append(receipt)
        if r.returncode:raise RuntimeError(name+' exited '+str(r.returncode)+'; see '+str(CHECK/(name+'-receipt.json')))
    expected='PASS counter_pixels=163840 vertical_increments=512 rejected_blank_carries=512 field_counter_clocks=81920 active_rows_per_field=224 ce_hold_checks=1474560'
    assert receipts[1]['stdout'].strip()==expected,receipts[1]['stdout']
    assert hashes=={s:sha(ROOT/s) for s in SOURCE},'source changed during qualification'
    result={'scope':'Connected related-board horizontal/vertical counters and VB latch, native isolated RTL only.',
            'native_exit':receipts[1]['exit_code'],'build_exit':receipts[0]['exit_code'],
            'summary':expected,'source_sha256':hashes,
            'executable_sha256':sha(CHECK/'build/Vraster_counter_qualification'),
            'receipts':['_checks/vertical-counter-20261010/build-receipt.json','_checks/vertical-counter-20261010/test-receipt.json'],
            'integrated_in_board':False,'sheriff_reset_origin_qualified':False,
            'graphics_gate_pass':False,'irq_phase_qualified':False,'timing_gate_pass':False,
            'quartus_executed':False,'rbf_built':False}
    (ROOT/'docs/evidence/sheriff_vertical_counter_native.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='')
    print(json.dumps({'native_exit':0,'summary':expected,'report':'docs/evidence/sheriff_vertical_counter_native.json'}))
if __name__=='__main__':main()
