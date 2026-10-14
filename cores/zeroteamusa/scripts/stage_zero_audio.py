"""Stage the target sound wrapper and unmodified Verilog TV80 donor."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
source = root / 'donors/raiden/rtl/Raiden/Raiden_audio_z80.sv'
lines = source.read_text(encoding='utf-8').splitlines()
def section(first, last):
    return '\n'.join(lines[first-1:last]) + '\n'

# Keep the donor's normal Seibu latch / interrupt controller, excluding its
# optional CPU register savestate backdoor. TV80 does not expose that API.
glue = section(324, 501)
import re
glue = re.sub(r'\s*else if \(glue_wr\) begin.*?\n\s*end else begin', '\n\t\telse begin', glue, flags=re.S)
glue = re.sub(r'\n\s*else if \(glue_wr\)\n\s*rom_bank <= glue_out\[0\];', '', glue)
glue = re.sub(r'\n\s*// pack glue per savestate.*?\n\s*// Latch al rising edge', '\n\t// Latch al rising edge', glue, flags=re.S)
glue = glue.replace('0x4007','0x401A')
glue = glue.replace('0xA0008','0x0710').replace('0xA0000','0x0700')
glue = glue.replace('0xA0002','0x0704').replace('0xA0004','0x0708')
glue = glue.replace('0xA0006','0x070C').replace('0xA000A','0x0714').replace('0xA000C','0x0718')
glue = glue.replace('bus_addr[3:1]', 'bus_addr[4:2]')

prefix = '''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
// Zero Team USA adaptation: exact MAME map, 96 MHz enables, plain ROM, TV80.
// Normal Seibu latch/IRQ logic derived from Arcade-Raiden_MiSTer,
// commit 28cd62a632f8a5c12dfc81e0882b9869ac57940d.
// No sound savestates are implemented. ROM download is raw 64 KiB LE words.
module ZeroTeam_audio (
    input wire clk,reset,pause,
    input wire ioctl_download,ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_dout,
    input wire snd_cs,snd_wr,snd_rd,
    input wire [2:0] snd_addr,
    input wire [15:0] snd_wdata,
    output wire [15:0] snd_rdata,
    input wire [7:0] coin_input,
    output wire [17:0] oki_rom_addr,
    input wire [7:0] oki_rom_data,
    input wire oki_rom_ok,
    output reg signed [15:0] audio_l,audio_r,
    output wire audio_sample,
    output wire [15:0] debug_address,
    output wire [7:0] debug_data,debug_din,
    output wire debug_read,debug_write,debug_fetch,debug_iack,
    output wire debug_cen,debug_ym_irq,debug_pending
);
    // 96 MHz * 105/2816 = 3.579545 MHz; *15/1408 = 1.022727 MHz.
    reg [11:0] z_acc;
    reg [10:0] o_acc;
    wire [12:0] z_next = {1'b0,z_acc}+13'd105;
    wire [11:0] o_next = {1'b0,o_acc}+12'd15;
    wire cen_z80 = z_next >= 13'd2816 && !pause;
    wire cen_oki = o_next >= 12'd1408 && !pause;
    always @(posedge clk) begin
        if(reset) begin z_acc<=0; o_acc<=0; end
        else if(!pause) begin
            z_acc <= z_next >= 2816 ? z_next-2816 : z_next;
            o_acc <= o_next >= 1408 ? o_next-1408 : o_next;
        end
    end
    wire [15:0] z80_addr;
    wire [7:0] z80_dout;
    reg [7:0] z80_din;
    wire z80_mreq_n,z80_iorq_n,z80_rd_n,z80_wr_n,z80_m1_n,z80_int_n;
    wire rom_lo_cs = !z80_mreq_n && z80_addr<16'h2000;
    wire rom_hi_cs = !z80_mreq_n && z80_addr[15];
    wire ram_cs = !z80_mreq_n && z80_addr>=16'h2000 && z80_addr<16'h2800;
    wire reg_cs = !z80_mreq_n && z80_addr[15:5]==11'h200;
    wire oki_cs = !z80_mreq_n && z80_addr==16'h6000;
    reg rom_bank;
    wire [15:0] rom_byte_addr = rom_hi_cs && rom_bank ? {1'b0,z80_addr[14:0]} : z80_addr;
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] rom_lo[0:32767],rom_hi[0:32767];
    reg [7:0] z80_rom_q;
    (* ramstyle="M10K,no_rw_check" *) reg [7:0] zram[0:2047];
    reg [7:0] z80_ram_q;
    always @(posedge clk) begin
        if(ioctl_download && ioctl_wr && ioctl_addr>=27'h0a0000 && ioctl_addr<27'h0b0000) begin
            rom_lo[ioctl_addr[15:1]] <= ioctl_dout[7:0];
            rom_hi[ioctl_addr[15:1]] <= ioctl_dout[15:8];
        end
        z80_rom_q <= rom_byte_addr[0] ? rom_hi[rom_byte_addr[15:1]] : rom_lo[rom_byte_addr[15:1]];
        if(cen_z80 && ram_cs && !z80_wr_n) zram[z80_addr[10:0]]<=z80_dout;
        z80_ram_q<=zram[z80_addr[10:0]];
    end
'''
decode = section(291,306).replace("5'h07", "5'h1A")
chips = '''
    wire [7:0] ym_dout,oki_dout;
    wire signed [15:0] ym_snd;
    wire signed [13:0] oki_sound;
    wire ym_sample,oki_sample;
    jtopl2 u_fm (
        .rst(reset),.clk(clk),.cen(cen_z80),.din(z80_dout),.addr(z80_addr[0]),
        .cs_n(~is_ym_access),.wr_n(z80_wr_n),.dout(ym_dout),.irq_n(ym_irq_n),
        .fmvol0(8'h10),.fmvol1(8'h10),.fmvol2(8'h10),.fmvol3(8'h10),
        .fmvol4(8'h10),.fmvol5(8'h10),.fmvol6(8'h10),.fmvol7(8'h10),.fmvol8(8'h10),
        .snd(ym_snd),.sample(ym_sample)
    );
    jt6295 #(.INTERPOL(1)) u_adpcm (
        .rst(reset),.clk(clk),.cen(cen_oki),.ss(1'b1),
        .wrn(~(oki_cs && !z80_wr_n)),.din(z80_dout),.dout(oki_dout),
        .rom_addr(oki_rom_addr),.rom_data(oki_rom_data),.rom_ok(oki_rom_ok),
        .chvol0(8'h10),.chvol1(8'h10),.chvol2(8'h10),.chvol3(8'h10),
        .sound(oki_sound),.sample(oki_sample)
    );
'''
cpu = '''
    tv80s u_z80 (
        .reset_n(~reset),.clk(clk),.cen(cen_z80),.wait_n(1'b1),
        .int_n(z80_int_n),.nmi_n(1'b1),.busrq_n(1'b1),
        .m1_n(z80_m1_n),.mreq_n(z80_mreq_n),.iorq_n(z80_iorq_n),
        .rd_n(z80_rd_n),.wr_n(z80_wr_n),.rfsh_n(),.halt_n(),.busak_n(),
        .A(z80_addr),.di(z80_din),.dout(z80_dout)
    );
    // MAME target routes: YM3812 1.0, OKI6295 0.5, mono.
    // Common 1/2 attenuation gives headroom while preserving their ratio.
    wire signed [17:0] mix = ($signed(ym_snd) >>> 1) + $signed(oki_sound);
    reg ym_sample_d;
    reg sample_pulse;
    always @(posedge clk) begin
        ym_sample_d<=ym_sample;
        sample_pulse<=ym_sample && !ym_sample_d && !pause;
        if(reset) begin audio_l<=0; audio_r<=0;ym_sample_d<=0;sample_pulse<=0;end
        else if(ym_sample && !ym_sample_d && !pause) begin
            audio_l<=mix>32767 ? 16'sh7fff : mix< -32768 ? 16'sh8000 : mix[15:0];
            audio_r<=mix>32767 ? 16'sh7fff : mix< -32768 ? 16'sh8000 : mix[15:0];
        end
    end
    assign audio_sample=sample_pulse;
    assign debug_address=z80_addr;
    assign debug_data=z80_dout;
    assign debug_din=z80_din;
    assign debug_read=!z80_mreq_n && !z80_rd_n;
    assign debug_write=!z80_mreq_n && !z80_wr_n;
    assign debug_fetch=!z80_m1_n && !z80_mreq_n;
    assign debug_iack=iack_active;
    assign debug_cen=cen_z80;
    assign debug_ym_irq=ym_irq;
    assign debug_pending=main2sub_pending;
endmodule
'''
target=root/'rtl/ZeroTeam_audio.sv'
target.write_text(prefix+decode+glue+chips+section(718,731)+cpu,encoding='utf-8')
tv=root/'rtl/tv80'
tv.mkdir(exist_ok=True)
for name in ('tv80s.v','tv80_core.v','tv80_alu.v','tv80_mcode.v','tv80_reg.v'):
    shutil.copy2(root/'donors/irem-m72/rtl/tv80'/name,tv/name)
shutil.copytree(root/'donors/raiden/rtl/sound/jtopl',root/'rtl/sound/jtopl',dirs_exist_ok=True)
acc=root/'rtl/sound/jt6295/jt6295_acc.v'
body=acc.read_text()
body=body.replace('"jt6295_up4.hex"','"rtl/sound/jt6295/jt6295_up4.hex"')
body=body.replace('"jt6295_up4_soft.hex"','"rtl/sound/jt6295/jt6295_up4_soft.hex"')
acc.write_text(body)
print('Staged ZeroTeam_audio and 5 unmodified TV80 sources')
