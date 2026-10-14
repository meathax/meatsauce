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

module jtsimson_obj #(parameter
    RAMW      = 12, // 12 -> 8kB
    PACKED    = 1,
    SHADOW    = 0,
    K55673    = 0,
    // K055673 sort direction is programmed by OBJSET2 register 6 bit 4.
    // The Metamorphic wrapper drives the runtime sort-direction input from
    // that register; this parameter remains only as the reset/default value.
    K55673_DESC_SORT = 0,
    // Set high to trigger DMA on the edge dma_en signal
    EDGE_TRIGGER = 0,
    parameter [9:0] HOFFSET   = 10'd62
)(
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
    // K053246 OBJSET1 register 5 bit 5 (SD0EN). When clear, GX shadow
    // code 1 turns the whole non-transparent sprite into preset-1 shadow.
    input             sd0en,
    // K055673 OBJSET2 word 6 bit 4 selects sprite Z-sort direction.
    input             k55673_desc_sort,

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
wire [22:1] rmrd_addr;
wire [13:1] dma_addr;
wire [18:0] pre_pxl;

// Draw module
wire        dr_start, dr_busy;
wire [15:0] code;
wire [ 9:0] attr;     // OC pins
wire        hflip, vflip, hz_keep, pre_cs;
wire [ 9:0] hpos;
wire [ 3:0] ysub;
wire [11:0] hzoom;
wire [31:0] sorted, sort_packed, sort_unpacked;

wire scr_hflip, scr_vflip;

assign rom_cs    = ~objcha_n | pre_cs;
assign rmrd_addr_o = rmrd_addr;
assign rom_addr  = !objcha_n ? rmrd_addr[22:2] :
    { pre_addr[22:7], pre_addr[5:2], pre_addr[6] };

assign cpu_din   = !objcha_n ? rmrd_addr[1] ? rom_data[31:16] : rom_data[15:0] :
                    ram_data;

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
// The line buffer keeps the shade of a shadow pixel apart from its colour, so a
// shadow-only pixel has no colour entry and would lose its priority. The shade
// field is therefore five bits wide: {shadow code, priority of the shadow sprite}.
// The colour entry never holds the shadow pen, so the pen is used as it is.
assign shd      = pre_pxl[18:17];
assign shd_prio = pre_pxl[16:14];
assign prio     = pre_pxl[13:9];
assign pxl      = gfx_en[3] ? {pre_pxl[8:4], pre_pxl[3:0]} : 9'd0;

// Simpsons, X-Men
jtframe_8x8x4_packed_msb u_packed(rom_data, sort_packed);

assign sorted = PACKED==1 ? sort_packed : rom_data;

jt053246 #(
    .K55673          ( K55673           ),
    .K55673_DESC_SORT( K55673_DESC_SORT ),
    .EDGE_TRIGGER    ( EDGE_TRIGGER     ),
    .HOFFSET         ( HOFFSET          )
) u_scan (    // sprite logic
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl2_cen   ( pxl2_cen  ),
    .pxl_cen    ( pxl_cen   ),
    .simson     ( simson    ),

    .ln_done    ( ln_done   ),
    .dma_enabled( dma_enabled_o ),
    .voffset    ( voffset   ),
    // CPU interface
    .cs         ( reg_cs    ),
    .cpu_we     ( mmr_we    ),
    .cpu_addr   ( mmr_addr  ),
    .cpu_dout   ( mmr_din   ),
    .cpu_dsn    ( mmr_dsn   ),
    .rmrd_addr  ( rmrd_addr ),

    // External RAM
    .dma_addr   ( dma_addr  ), // up to 16 kB
    .dma_data   ( dma_data  ),
    .dma_bsy    ( dma_bsy   ),
    .k55673_desc_sort( k55673_desc_sort ),

    // ROM addressing 22 bits in total
    .code       ( code      ),
    .attr       ( attr      ),     // OC pins
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
    .st_addr    ( ioctl_ram ? ioctl_addr[7:0] : debug_bus ),
    .st_dout    ( dump_reg  )
);

// The shadow field is a per-sprite attribute and every Violent Storm sprite
// carries a non-zero one. Only the shadow pen (15) may add shade to the line
// buffer: a solid pixel must not keep its own shade bits, otherwise the buffer
// cannot tell it from a shadow and never clears the shade left by a sprite
// behind it, so that shadow ends up on top of the nearer sprite.
wire [18:0] buf_pred;
// Shadow code 3 is MAME's SKIPSHADOW: the sprite has no shadow pass, and its
// solid pass leaves the shadow pen out. Its pen-15 pixels are therefore
// transparent; written as shade they would replace the shadows of every
// sprite drawn before them (the big zoomed sprites that carry code 3 are drawn
// last).
wire        pen_shadow = SHADOW==1 && buf_pred[3:0]==SHADOW_PEN && buf_pred[18:17]!=2'd0;
// GX/K055673 rule from MAME: with OBJSET1 SD0EN clear, raw shadow code 1
// is a full-shadow sprite. Every non-transparent pen contributes shadow and
// the solid colour pass is suppressed. Codes 2/3 retain pen-15 semantics
// (code 3 is SKIPSHADOW below).
wire        full_shadow = SHADOW==1 && !sd0en && buf_pred[18:17]==2'd1 &&
                          buf_pred[3:0]!=4'd0;
wire        skip_px    = pen_shadow && buf_pred[18:17]==2'd3;
wire        shadow_px  = (pen_shadow && !skip_px) || full_shadow;
wire        suppress_solid = skip_px || full_shadow;
wire [18:0] buf_din    = { shadow_px ? buf_pred[18:14] : 5'd0,
                           buf_pred[13:4], suppress_solid ? 4'd0 : buf_pred[3:0] };

jtviostorm_objdraw_gate #(
    .SHADOW(SHADOW),.SHADOW_PEN(SHADOW_PEN),
    // Metamorphic translates HCT across a 9-bit wrap before visible x24.
    // Preserve that wrap instead of extending it into the other buffer half.
    .HFIX(0),.AW(10),.CW(16),.PW(4+10+5),.LATCH(1),.SWAPH(1),
    .ZW(12),.ZI(6), .ZENLARGE(1),.SW(5),.FLIP_OFFSET(9'h12)
) u_draw(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( pxl_cen       ),

    .hs         ( hs            ),
    .flip       ( screen_hflip  ),
    .hdump      ( {1'b0,hdump}  ),

    .draw       ( dr_start      ),
    .busy       ( dr_busy       ),
    .code       ( code          ),
    .xpos       ( hpos          ),
    .ysub       ( ysub          ),
    .trunc      ( 2'd0          ),
    .hz_keep    ( hz_keep       ),
    .hzoom      ( hzoom         ),

    .hflip      ( ~hflip        ),
    .vflip      ( vflip         ),
    .pal        ({pre_shd, attr[7:5], attr}),

    .rom_addr   ( pre_addr      ),
    .rom_cs     ( pre_cs        ),
    .rom_ok     ( rom_ok        ),
    .rom_data   ( sorted        ),

    .buf_pred   ( buf_pred      ),
    .buf_din    ( buf_din       ),

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
