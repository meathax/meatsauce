#!/usr/bin/env python3
"""Measure production FM enables and exercise the actual shift/ROM pair."""
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path('/mnt/r/Verilator/zero-opl-phase-checks')
build.mkdir(parents=True, exist_ok=True)
audio = (root / 'rtl/ZeroTeam_audio.sv').read_text()
start = audio.index('    reg [11:0] z_acc=0;')
end = audio.index('\n    end', start) + len('\n    end')
generator = audio[start:end]
opl = root / 'rtl/sound/jtopl'
harness = build / 'timing_opl_phase.sv'
harness.write_text('''module timing_opl_phase(input clk,pause,reset,input [7:0] din,
 input signed [12:0] operator_data,input rhythm,
 output ce_z80,cenop,output [7:0] shifted,output [11:0] lookup,
 output [17:0] slot,output [12:0] held_operator,output [13:0] gain_result);
''' + generator + '''
assign ce_z80=cen_z80;
jtopl_div #(.OPL_TYPE(2)) div(reset,clk,cen_z80,cenop);
jtopl_sh #(.width(8),.stages(3)) sh(clk,cenop,din,shifted);
jtopl_logsin lut(clk,cenop,shifted,lookup);
wire slot_zero,slot_op;
jtopl_slot_cnt slots(.rst(reset),.clk(clk),.cen(cenop),.zero(slot_zero),
 .group(),.op(slot_op),.subslot(),.slot(slot));
reg [12:0] op_hold=0;
always @(posedge clk) if(cenop) op_hold<=operator_data;
assign held_operator=op_hold;
jtopl_acc acc(.rst(reset),.clk(clk),.cenop(cenop),.slot(slot),.rhy_en(rhythm),
 .op_result(op_hold),.zero(slot_zero),.op(slot_op),.con(1'b1),
 .fmvol0(8'h10),.fmvol1(8'h10),.fmvol2(8'h10),.fmvol3(8'h10),
 .fmvol4(8'h10),.fmvol5(8'h10),.fmvol6(8'h10),.fmvol7(8'h10),.fmvol8(8'h10),.snd());
assign gain_result=acc.op2x_g_q;
endmodule
''')
table = re.findall(r"sinelut\[8'd(\d+)\]\s*=\s*12'h([0-9a-f]+)",
    (opl / 'jtopl_logsin.v').read_text())
assert len(table) == 256
values = {int(index):int(value,16) for index,value in table}
(build / 'sine_table.h').write_text('static const unsigned sine_table[256]={'
    + ','.join(str(values[i]) for i in range(256)) + '};\n')
log = root / 'sim/results/timing_opl_phase_build.log'
log.parent.mkdir(parents=True, exist_ok=True)
with log.open('w') as output:
    subprocess.run(['verilator','--cc','--exe','--build','-j','4','--no-timing',
        # Preserve the production generator's deliberate accumulator narrowing.
        '-Wno-WIDTHTRUNC','-DSIMULATION','--top-module','timing_opl_phase','--Mdir',str(build),str(harness),
        str(opl/'jtopl_div.v'),str(opl/'jtopl_sh.v'),str(opl/'jtopl_logsin.v'),
        str(opl/'jtopl_slot_cnt.v'),str(opl/'jtopl_acc.v'),str(opl/'jtopl_single_acc.v'),
        str(root/'sim/timing_opl_phase.cpp'),'-CFLAGS','-std=c++17 -O2'],
        stdout=output,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(build/'Vtiming_opl_phase')],check=True)
