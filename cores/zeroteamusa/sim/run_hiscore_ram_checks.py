#!/usr/bin/env python3
"""Check the actual small-table RAM against its registered dual-port contract."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-hiscore-ram-checks')
build.mkdir(parents=True, exist_ok=True)
source = (root / 'rtl/hiscore.v').read_text()
module = re.search(r'module dpram_hs\b.*?endmodule', source, re.S).group()
harness = build / 'hiscore_ram_checks.sv'
harness.write_text(module + '''
module hiscore_ram_checks(input clk, input [1:0] aa,ab,
 input [23:0] da,db, input wa,wb, output [23:0] qa,qb,auto_qa,auto_qb);
dpram_hs #(.aWidth(2),.dWidth(24),.ramStyle("logic")) a(clk,aa,da,wa,qa,ab,db,wb,qb);
dpram_hs #(.aWidth(2),.dWidth(24),.ramStyle("auto")) b(clk,aa,da,wa,auto_qa,ab,db,wb,auto_qb);
endmodule
''')
log = root / 'sim/results/hiscore_ram_checks_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator', '--cc', '--exe', '--build', '-j', '4',
        '--no-timing', '--top-module', 'hiscore_ram_checks', '--Mdir', str(build),
        str(harness), str(root / 'sim/hiscore_ram_checks.cpp'),
        '-CFLAGS', '-std=c++17 -O2'], stdout=output, stderr=subprocess.STDOUT, check=True)
subprocess.run([str(build / 'Vhiscore_ram_checks')], check=True)
