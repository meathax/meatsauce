#!/usr/bin/env python3
"""Check production parallel-borrow timer arithmetic, including 32-bit wrap."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-hiscore-timer-checks')
build.mkdir(parents=True, exist_ok=True)
source = (root / 'rtl/hiscore.v').read_text()
function = re.search(r'function automatic \[31:0\] decrement_wait_timer;.*?endfunction', source, re.S).group()
harness = build / 'hiscore_timer_checks.sv'
harness.write_text('module hiscore_timer_checks(input [31:0] timer, output [31:0] result);\n'
    + function + '\nassign result=decrement_wait_timer(timer);\nendmodule\n')
log = root / 'sim/results/hiscore_timer_checks_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator', '--cc', '--exe', '--build', '-j', '4', '--no-timing',
        '--top-module', 'hiscore_timer_checks', '--Mdir', str(build), str(harness),
        str(root / 'sim/hiscore_timer_checks.cpp'), '-CFLAGS', '-std=c++17 -O2'],
        stdout=output, stderr=subprocess.STDOUT, check=True)
subprocess.run([str(build / 'Vhiscore_timer_checks')], check=True)
