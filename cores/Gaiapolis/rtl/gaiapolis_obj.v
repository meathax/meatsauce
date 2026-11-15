/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 24-7-2023 */

module gaiapolis_obj #(parameter
    RAMW      = 12, // 12 -> 8kB
    PACKED    = 1,
    SHADOW    = 0,
    K55673    = 0,
    // K55673 (used with K53246 on Run'n Gun) uses ascending order
    // This is actually programmed on register 12, bit 4, but
    // it is never changed. Other register functions are unknown
    // so I am leaving it static for now
    K55673_DESC_SORT = 0,
    // Set high to trigger DMA on the edge dma_en signal
    EDGE_TRIGGER = 0,
    parameter integer HACTIVE_FIRST=106,VACTIVE_FIRST=271,HCOUNTER_PHASE=-1,
    parameter integer BITMAP_LEFT=40,BITMAP_TOP=16,SPRITE_DX=-61,SPRITE_DY=-22,
    parameter [9:0] HOFFSET   = 10'd62
)(
    input wire monster,
    output logic [1:0] sprite_mix,
    output wire [18:0] sprite5_addr,
    output wire sprite5_cs,
    input wire [31:0] sprite5_data,
    input wire sprite5_ok,
    input             rst,
    input             clk,
    output            ln_done,
    output            dma_enabled_o,

    input             pxl_cen,
    input             pxl2_cen,
    input             simson,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input      [ 9:0] voffset,
    input             hs,
    input             lvbl,
    // OBJSET1 register 5 bit 0.  K053246 documents this as the
    // horizontal screen-flip control.  The scanner consumes the same
    // register for object-coordinate transforms; the line buffer also
    // needs the bit so its read address follows the flipped raster.
    input             screen_hflip,
    input [63:0] objset1,
    input [127:0] objset2,
    input [23:0] shadow_priorities,
    output [7:0] shadow_priority_full,
    output [31:0] solid_order,shadow_order,
    output [7:0] shadow_ops_valid,
    output [15:0] shadow_ops_mode,
    output [255:0] shadow_ops_order,
    output shadow_ops_overflow,
    output line_overrun,

    // CPU interface
    input             ram_cs,
    input             reg_cs,
    input             mmr_we,
    input      [ 3:0] mmr_addr,
    input      [15:0] mmr_din,
    input      [ 1:0] mmr_dsn,

    input      [15:0] ram_din, // 16-bit interface
    input      [ 1:0] ram_we,
    input    [RAMW:1] ram_addr,
    output     [15:0] cpu_din,
    output            dma_bsy,

    // ROM addressing
    output     [22:2] rom_addr,
    // K053246's composed ROM-readback address. The donor stores this in
    // bit-1-shifted form because the original CPU interface is byte based.
    output     [22:1] rmrd_addr_o,
    input      [31:0] rom_data,
    output            rom_cs,
    input             rom_ok,
    input             objcha_n,

    // pixel output
    output     [ 1:0] shd,      // shadow
    output     [ 2:0] shd_prio, // priority of the sprite that cast the shadow
    output     [ 4:0] prio,
    output     [ 9:0] pxl,

    // debug
    input      [ 3:0] gfx_en,
    input             ioctl_ram,
    input      [13:0] ioctl_addr,
    output     [ 7:0] dump_ram,
    output     [ 7:0] dump_reg,
    input      [ 7:0] debug_bus
);
// Exact geometry/control engine; original JTFRAME CPU RAM remains at u_ram.
wire [15:0] ram_data,dma_data;
wire [10:0] dma_word_addr;
wire [8:0] bitmap_buf_addr;
wire [18:0] bitmap_buf_data;
wire bitmap_buf_we;
wire [8:0] native_hpos=hdump-9'd32;
wire [23:0] read_raw={objset1[55:48],objset1[63:56],objset1[39:32]};
wire [21:0] read_word={read_raw[21:2],2'd0};
assign rmrd_addr_o=read_word;
assign cpu_din=!objcha_n ? (read_word[0] ? rom_data[31:16] : rom_data[15:0]) : ram_data;
assign dump_reg=objset1[debug_bus[2:0]*8+:8];
gaiapolis_sprite_engine #(
    .HACTIVE_FIRST(HACTIVE_FIRST),.VACTIVE_FIRST(VACTIVE_FIRST),
    .BITMAP_LEFT(BITMAP_LEFT),.BITMAP_TOP(BITMAP_TOP),
    .SPRITE_DX(SPRITE_DX),.SPRITE_DY(SPRITE_DY)
) u_engine(
        .monster(monster),
        .sprite_mix(sprite_mix),
        .sprite5_addr(sprite5_addr),.sprite5_cs(sprite5_cs),
        .sprite5_data(sprite5_data),.sprite5_ok(sprite5_ok),
    .clk(clk),.rst(rst),.pxl_cen(pxl_cen),.pxl2_cen(pxl2_cen),
    .hs(hs),.lvbl(lvbl),.hpos(native_hpos),.vpos(vdump),
    .objset1(objset1),.objset2(objset2),.shadow_priorities(shadow_priorities),
    .dma_word_addr(dma_word_addr),.dma_data(dma_data),
    .dma_busy(dma_bsy),.dma_irq_enabled(dma_enabled_o),
    .ln_done(ln_done),.line_overrun(line_overrun),
    .rom_addr(rom_addr),.rom_cs(rom_cs),.rom_data(rom_data),.rom_ok(rom_ok),
    .pixel(pxl),.prio(prio),.shadow(shd),.shadow_prio(shd_prio),
    .shadow_priority_full(shadow_priority_full),
        .solid_order(solid_order),.shadow_order(shadow_order),
        .shadow_ops_valid(shadow_ops_valid),.shadow_ops_mode(shadow_ops_mode),
        .shadow_ops_order(shadow_ops_order),.shadow_ops_overflow(shadow_ops_overflow),
    .buf_addr(bitmap_buf_addr),.buf_data(bitmap_buf_data),.buf_we(bitmap_buf_we)
);
jtframe_dual_nvram16 #(.AW(RAMW),.SIMFILE("obj.bin")) u_ram(
    .clk0(clk),.data0(ram_din),.addr0(ram_addr),.we0(ram_we&{2{ram_cs}}),.q0(ram_data),
    .clk1(clk),.addr1a({{RAMW-11{1'b0}},dma_word_addr}),.q1a(dma_data),
    .data1(8'd0),.addr1b(ioctl_addr[RAMW:0]),.we1b(1'b0),.q1b(dump_ram),.sel_b(ioctl_ram)
);
wire unused_legacy=&{1'b0,ioctl_addr[13:RAMW+1],debug_bus[7:3],read_raw[23:22],read_raw[1:0],simson,screen_hflip,voffset,reg_cs,mmr_we,mmr_addr,
                     mmr_din,mmr_dsn,gfx_en,bitmap_buf_addr,bitmap_buf_data,bitmap_buf_we,
                     PACKED[31:0],SHADOW[31:0],K55673[31:0],K55673_DESC_SORT[31:0],
                     EDGE_TRIGGER[31:0],HOFFSET,HCOUNTER_PHASE[31:0]};
endmodule

module gaiapolis_sprite_callback(
    input [9:0] raw_color,
    input [3:0] pen,
    input enable,
    output [9:0] pixel,
    output [4:0] prio
);
assign pixel=enable ? {raw_color[9],raw_color[4:0],pen} : 10'd0;
assign prio={2'b00,raw_color[7:5]};
endmodule
