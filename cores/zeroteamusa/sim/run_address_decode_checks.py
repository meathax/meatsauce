#!/usr/bin/env python3
"""Exhaust every decoder input against the preserved pre-closure RTL."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-address-decode-checks')
build.mkdir(parents=True, exist_ok=True)
source = root / 'rtl/Raiden2/raiden2_addr_main.sv'
# Fixed repository baseline, independent of future decoder edits or HEAD.
baseline = subprocess.check_output(['git','show',
    'fd97f89:rtl/Raiden2/raiden2_addr_main.sv'],cwd=root,text=True)
reference = build / 'address_decode_reference.sv'
reference.write_text(baseline.replace('module raiden2_addr_main',
    'module address_decode_reference',1))
ports = re.findall(r'output\s+logic\s*(\[[^]]+\])?\s*(\w+)',baseline)
assert len(ports) == 23
inputs = ['A','DBEN','rom_bank','board_dx','dx_prg_bank']
harness = ['module address_decode_checks(input [19:0] A,input DBEN,rom_bank,',
    'board_dx,input [3:0] dx_prg_bank,output mismatch);']
for prefix in ['actual','expected']:
    harness += [f'wire {width} {prefix}_{name};' for width,name in ports]
    module = 'raiden2_addr_main' if prefix == 'actual' else 'address_decode_reference'
    links = [f'.{name}({name})' for name in inputs]
    links += [f'.{name}({prefix}_{name})' for _,name in ports]
    harness += [f'{module} {prefix}_dut('+','.join(links)+');']
packed = lambda prefix: '{'+','.join(prefix+'_'+name for _,name in ports)+'}'
harness += ['assign mismatch='+packed('actual')+' != '+packed('expected')+';',
    'endmodule']
top = build / 'address_decode_checks.sv'
top.write_text('\n'.join(harness)+'\n')
log = root / 'sim/results/address_decode_checks_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator','--cc','--exe','--build','-j','4','--no-timing',
        '--top-module','address_decode_checks','--Mdir',str(build),str(top),
        str(source),str(reference),str(root/'sim/address_decode_checks.cpp'),
        '-CFLAGS','-std=c++17 -O2'],stdout=output,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(build/'Vaddress_decode_checks')],check=True)
