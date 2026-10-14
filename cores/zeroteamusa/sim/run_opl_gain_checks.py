#!/usr/bin/env python3
"""Exhaust the production OPL gain/clamp arithmetic against its contract."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-opl-gain-checks')
build.mkdir(parents=True, exist_ok=True)
opl = root / 'rtl/sound/jtopl'
harness = build / 'opl_gain_checks.sv'
harness.write_text('''module opl_gain_checks(input clk,input [17:0] slot,
 input rhy_en,input signed [12:0] sample,input [7:0] volume,
 output signed [13:0] gain);
 wire signed [15:0] snd;
 jtopl_acc dut(.rst(1'b0),.clk(clk),.cenop(1'b0),.slot(slot),
 .rhy_en(rhy_en),.op_result(sample),.zero(1'b0),.op(1'b0),.con(1'b0),
 .fmvol0(volume),.fmvol1(volume),.fmvol2(volume),.fmvol3(volume),
 .fmvol4(volume),.fmvol5(volume),.fmvol6(volume),.fmvol7(volume),
 .fmvol8(volume),.snd(snd));
 assign gain=dut.op2x_g;
endmodule
''')
log = root / 'sim/results/opl_gain_checks_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator','--cc','--exe','--build','-j','4',
        '--no-timing','--top-module','opl_gain_checks','--Mdir',str(build),
        str(harness),str(opl/'jtopl_acc.v'),str(opl/'jtopl_single_acc.v'),
        str(root/'sim/opl_gain_checks.cpp'),'-CFLAGS','-std=c++17 -O2'],
        stdout=output,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(build/'Vopl_gain_checks')],check=True)
