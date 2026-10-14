#!/usr/bin/env python3
"""Prove the production sprite X-coordinate expression over its full bit domain."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-sprite-position-checks')
build.mkdir(parents=True, exist_ok=True)
source = (root / 'rtl/Raiden2/Raiden2_sprite_renderer.sv').read_text()
function = re.search(r'function signed \[10:0\] dx_at;.*?endfunction', source, re.S).group()
base = re.search(r'wire signed \[10:0\] base_x\s*=.*?;', source, re.S)
harness = build / 'sprite_position_checks.sv'
harness.write_text('''module sprite_position_checks(input signed [10:0] sp_x,
 input [3:0] tile_x_pf, input sp_flipx,pf_side, input [2:0] k,
 output signed [10:0] dx);
''' + (base.group() if base else '') + function + '''
assign dx=dx_at({29'd0,k});
endmodule
''')
log = root / 'sim/results/sprite_position_checks_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator', '--cc', '--exe', '--build', '-j', '4',
        '--no-timing', '--top-module', 'sprite_position_checks', '--Mdir', str(build),
        str(harness), str(root / 'sim/sprite_position_checks.cpp'),
        '-CFLAGS', '-std=c++17 -O2'], stdout=output, stderr=subprocess.STDOUT, check=True)
subprocess.run([str(build / 'Vsprite_position_checks')], check=True)
