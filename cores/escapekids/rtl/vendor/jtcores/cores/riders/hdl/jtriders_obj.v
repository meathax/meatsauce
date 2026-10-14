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
    Date: 21-8-2024 */

// 053244/5
module jtriders_obj #(parameter
    RAMW   = 12,
    HFLIP_OFFSET = 0,
    SHADOW = 0,
    GX975  = 0
)(
    input             rst,
    input             clk,

    input             pxl_cen,
    input             pxl2_cen,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input             hs,
    input             lvbl,
    input             lgtnfght,
    input             esckids,

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
    output     [21:2] rom_addr,
    input      [31:0] rom_data,
    output            rom_cs,
    input             rom_ok,
    input             objcha_n,

    // pixel output
    output     [ 1:0] shd,      // shadow preset
    output     [ 4:0] prio,
    output     [ 8:0] pxl,

    // debug
    input      [ 3:0] gfx_en,
    input             ioctl_ram,
    input      [13:0] ioctl_addr,
    output     [ 7:0] dump_ram,
    output     [ 7:0] dump_reg,
    input      [ 7:0] debug_bus
);

localparam SHADOW_PEN = SHADOW[0]==1 ? 4'd15 : 4'd0;

wire [ 1:0] pre_shd;
wire [ 3:0] pen_eff;
wire [15:0] ram_data, dma_data;
wire [22:2] pre_addr;
wire [21:1] rmrd_addr;
wire [13:1] scn_addr, dma_addr;
wire [15:0] pre_pxl;

// Draw module
wire        dr_start, dr_busy;
wire [15:0] code;
wire [ 9:0] attr;     // OC pins / GX975 color word
wire        hflip, vflip, hz_keep, pre_cs;
wire [ 9:0] hpos;
wire [ 3:0] ysub;
wire [11:0] hzoom;
wire        pen15;
wire [ 7:0] obj_zcode;

wire scr_hflip, scr_vflip;

function [5:0] paroda_conv(input [5:0]x);
    paroda_conv = { x[5], x[3], x[1], x[4], x[2], x[0] };
endfunction

// jtframe_draw's pxl extraction ( {pxl_data[24],pxl_data[16],pxl_data[8],pxl_data[0]},
// shifting one bit position per pixel ) expects the donor K053244/5 physical
// ROM format: 4 separate 1-bit bitplanes, one full byte per plane, 8 pixels
// per 32-bit fetch. Escape Kids' K053246/053247 pair instead stores sprite
// tiles PACKED 4bpp (2 pixels per byte, both nibbles complete pixels) per
// MAME src/mame/konami/k053246_k053247_k055673.cpp
// k053247_device::device_start() "static const gfx_layout spritelayout":
//   planeoffset { 0,1,2,3 } (all 4 bitplanes inside one nibble)
//   xoffset     { 2*4,3*4,0*4,1*4, 6*4,7*4,4*4,5*4, ... } *4-bit nibbles
//   charincrement 128*8 (128 bytes/tile, matching the esckids linear
//   code*128 addressing already used above)
// For one 32-bit fetch (bytes d[7:0]/d[15:8]/d[23:16]/d[31:24] = half a tile
// row = 8 pixels), MAME's xoffset {2*4,3*4,0*4,1*4,6*4,7*4,4*4,5*4} is a BIT
// offset table read with drawgfx's MSB-first readbit convention
// (src[off/8] & (0x80 >> off%8), plane p -> pen bit 3-p). Bit offset 4n
// therefore lands in region byte n>>1, in the HIGH nibble when n is even and
// the LOW nibble when n is odd, with the nibble holding the pen value as-is.
// Composed with the little-endian 32-bit fetch, screen pixel s=0..7 takes the
// nibble at d[4*{3,2,1,0,7,6,5,4}[s] +: 4]: within each 16-bit word the HIGH
// byte's two pixels come first, high nibble before low - i.e. the OBJ ROM
// data bus shifts the high byte lane out first, big-endian pixel order inside
// each little-endian-stored word (consistent with MAME's ROM_LOAD64_WORD
// region build for the 975c04-07 ROMs). Proven exhaustively: a Python decode
// of all 524288 rows of the real interleaved 4MB sprite region with MAME's
// exact readbit algorithm matches this mapping with zero mismatches, and the
// same model byte-for-byte reproduces live Verilator frame captures. An
// earlier revision used nibble-index {2,3,0,1,6,7,4,5} directly (LSB-first
// nibble numbering) which swapped every adjacent pixel pair: INSERT COIN
// glyphs garbled with doubled verticals, coin disc and drop shadow scrambled,
// US flag star field and stripes broken. This function re-packs the 8 pixel
// nibbles into the bit-planar layout jtframe_draw natively expects.
//
// Bit order within each plane byte: this module drives jtframe_objdraw with
// .hflip(~hflip) (donor 053244/5 ROM convention), so for an UNFLIPPED sprite
// jtframe_draw runs its hflip==1 path, emitting plane bit 7 first and shifting
// left. The screen-leftmost pixel of the fetch must therefore sit in bit 7 of
// each plane byte (p0 at bit 7 ... p7 at bit 0). The original packing put p0
// at bit 0, which made every 8-pixel fetch come out horizontally mirrored in
// place: coin -> symmetric speckled blob, drop shadow -> "bowtie", INSERT
// COIN glyphs mirrored, character sprites doubled-arm composites (directed
// identity-ROM testbench rtl/esckids/verify/tb_esckids_obj_ghost.sv: 160/160
// pens reversed per 8-pixel group before this fix, 160/160 correct after).
function [31:0] gx975_unswizzle(input [31:0] d);
    reg [3:0] p0,p1,p2,p3,p4,p5,p6,p7;
    begin
        p0 = d[15:12]; p1 = d[11:8];  p2 = d[7:4];   p3 = d[3:0];
        p4 = d[31:28]; p5 = d[27:24]; p6 = d[23:20]; p7 = d[19:16];
        gx975_unswizzle[7:0]   = {p0[0],p1[0],p2[0],p3[0],p4[0],p5[0],p6[0],p7[0]};
        gx975_unswizzle[15:8]  = {p0[1],p1[1],p2[1],p3[1],p4[1],p5[1],p6[1],p7[1]};
        gx975_unswizzle[23:16] = {p0[2],p1[2],p2[2],p3[2],p4[2],p5[2],p6[2],p7[2]};
        gx975_unswizzle[31:24] = {p0[3],p1[3],p2[3],p3[3],p4[3],p5[3],p6[3],p7[3]};
    end
endfunction

wire [31:0] draw_rom_data = esckids ? gx975_unswizzle(rom_data) : rom_data;

assign rom_cs    = ~objcha_n | pre_cs;
// paroda_conv (with the ysub[3]/H position swap below it) reproduces the
// K053244/5 zoom-hardware ROM quadrant scramble used by parodius/lgtnfght/
// simpsons. GX975 (Escape Kids) instead drives a plain K053246/053247 pair
// (see MAME src/mame/konami/vendetta.cpp "ESCAPE KIDS uses 053246's unknown
// function" and k053246_k053247_k055673.cpp k053247_device::device_start()
// spritelayout), whose tile ROM is stored linearly: code*128 + y*8 + H*4
// bytes, no address-bit scramble. Route esckids straight through with H as
// the low-order selector instead of applying the donor-chip scramble.
assign rom_addr  = !objcha_n ? rmrd_addr[21:2] :
    esckids ? { pre_addr[21:7], pre_addr[5:2], pre_addr[6] } :
    { pre_addr[21], pre_addr[20:13], paroda_conv(pre_addr[12:7]), pre_addr[5], pre_addr[6],  pre_addr[4:2] };

assign cpu_din   = !objcha_n ? rmrd_addr[1] ? rom_data[31:16] : rom_data[15:0] :
                    ram_data;
assign dma_addr  = lgtnfght ? {scn_addr[10:4],2'b00,scn_addr[3:1],1'b0} : scn_addr;

// Shadow understanding so far
// The 053251 color mixer lets shadow pass based on numerical priority only
// and independently of what layer is selected. As the object layer should not
// be drawn directly over a shadow, it looks like the logic must be like this
// - in the LUT the shadow bits are set for the whole sprite
// - when drawing the sprite, if the shadow is enabled and the sprite pen is
//   15 (bits 3:0 high), output the shadow bits but set the pen to 0 (transparent)
// - otherwise, output 0 for shadow bits and let the pen go through unaltered
// - Some bits in upper byte of register 2 are unknown in MAME and could be
//   related to selecting shadow pens
// 053244 (parodius) has 7 palette bits, top 2 used for priority
assign pen15   = &pre_pxl[3:0];
assign pen_eff = (pre_pxl[15:14]==0 || !pen15) ? pre_pxl[3:0] : 4'd0; // real color or 0 if shadow
assign shd     =  pre_pxl[15:14];
assign prio    =  esckids ? pre_pxl[13:9] : {1'd1,pre_pxl[10:9],2'd0};
assign pxl     = gfx_en[3] ? {pre_pxl[8:4], pen_eff} : 9'd0;

jt053244 #(.HFLIP_OFFSET(HFLIP_OFFSET), .GX975(GX975)
    )u_scan(    // sprite logic
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl2_cen   ( pxl2_cen  ),
    .pxl_cen    ( pxl_cen   ),

    // CPU interface
    .cs         ( reg_cs    ),
    .cpu_we     ( mmr_we    ),
    .cpu_addr   ( mmr_addr  ),
    .cpu_dout   ( mmr_din   ),
    .cpu_dsn    ( mmr_dsn   ),
    .rmrd_addr  ( rmrd_addr ),

    // External RAM
    .dma_addr   ( scn_addr  ), // up to 16 kB
    .dma_data   ( dma_data  ),
    .dma_bsy    ( dma_bsy   ),

    // ROM addressing 22 bits in total
    .code       ( code      ),
    .attr       ( attr      ),     // OC pins
    .zcode      ( obj_zcode ),
    .hflip      ( hflip     ),
    .vflip      ( vflip     ),
    .hpos       ( hpos      ),
    .ysub       ( ysub      ),
    .hzoom      ( hzoom     ),
    .hz_keep    ( hz_keep   ),

    // control
    .hdump      ( hdump     ),
    .vdump      ( vdump     ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),

    // shadow
    .pxl        ( pxl       ),
    .shd        ( pre_shd   ),

    // draw module / 053247
    .dr_start   ( dr_start  ),
    .dr_busy    ( dr_busy   ),

    // Debug
    .debug_bus  ( debug_bus ),
    .gx975      ( esckids   ),
    .st_addr    ( ioctl_ram ? ioctl_addr[7:0] : debug_bus ),
    .st_dout    ( dump_reg  )
);

jtframe_objdraw #(
    .SHADOW(SHADOW),.SHADOW_PEN(SHADOW_PEN),.SW(2),
    .ZMODE(GX975),.ZBUF_W(8),.PRIOW(5),
    .AW(10),.CW(16),.PW(4+10+2),.LATCH(1),.SWAPH(1),
    .ZW(12),.ZI(6),.ZENLARGE(1),
    .FLIP_OFFSET(9'h12),.KEEP_OLD(0)
) u_draw(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( pxl_cen       ),

    .hs         ( hs            ),
    .flip       ( 1'b0          ),
    .hdump      ( {1'b0,hdump}  ),

    .draw       ( dr_start      ),
    .busy       ( dr_busy       ),
    .code       ( code          ),
    .xpos       ( hpos          ),
    .ysub       ( ysub          ),
    .hz_keep    ( hz_keep       ),
    .hzoom      ( hzoom         ),

    .hflip      ( ~hflip        ),
    .vflip      ( vflip         ),
    .pal        ({pre_shd,attr}),
    .obj_z     ( obj_zcode ),
    .obj_prio  ( esckids ? attr[9:5] : 5'd0 ),
    .z_enable  ( esckids ),

    .rom_addr   ( pre_addr      ),
    .rom_cs     ( pre_cs        ),
    .rom_ok     ( rom_ok        ),
    .rom_data   ( draw_rom_data ),

    .pxl        ( pre_pxl       )
);

jtframe_dual_nvram16 #(
    .AW     ( RAMW    ),
    .SIMFILE("obj.bin")
) u_ram( // 8 or 16kB? check PCB. Game seems to work on 8kB ok
    // Port 0 - CPU access
    .clk0   ( clk       ),
    .data0  ( ram_din   ),
    .addr0  ( ram_addr  ),
    .we0    ( ram_we & {2{ram_cs}} ),
    .q0     ( ram_data  ),
    // Port 1 - Video access
    .clk1   ( clk       ),
    .addr1a ( dma_addr[RAMW:1] ),
    .q1a    ( dma_data  ),
    // 8-bit IOCTL access
    .data1  ( 8'd0      ),
    .addr1b ( ioctl_addr[RAMW:0] ),
    .we1b   ( 1'd0      ),
    .q1b    ( dump_ram  ),
    .sel_b  ( ioctl_ram )
);

endmodule
