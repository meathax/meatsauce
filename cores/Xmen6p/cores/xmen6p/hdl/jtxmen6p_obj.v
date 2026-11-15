/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 24-7-2023 */

module jtxmen6p_obj #(parameter
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
    parameter [9:0] HOFFSET   = 10'd62
)(
    input             rst,
    input             clk,
    output            ln_done,

    input             pxl_cen,
    input             pxl2_cen,
    input             simson,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input      [ 9:0] voffset,
    input             hs,
    input             lvbl,

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
    // X-Men 6P: sprite list for the screen being drawn. MAME copies 4 kB from
    // 100000 (left) or 102000 (right) into the 053247 at VB start.
    input             dma_bank,
    input             bank_load,  // VB start: apply the latched 053246 registers
    output            copy_busy,  // sprite list snapshot in progress (hold CPU)
    output     [15:0] cpu_din,
    output            dma_bsy,

    // ROM addressing
    output     [22:2] rom_addr,
    input      [31:0] rom_data,
    output            rom_cs,
    input             rom_ok,
    input             objcha_n,

    // pixel output
    output     [ 1:0] shd,      // shadow
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
wire [15:0] ram_data, dma_data, dma_rdata, dma_snap;
wire [13:1] dma_raddr;
wire [22:2] pre_addr;
wire [22:1] rmrd_addr;
wire [13:1] dma_addr;
wire [15:0] pre_pxl;

// Draw module
wire        dr_start, dr_busy;
wire [15:0] code;
wire [ 9:0] attr;     // OC pins
wire        hflip, vflip, hz_keep, pre_cs;
wire [ 9:0] hpos;
wire [ 3:0] ysub;
wire [11:0] hzoom;
wire [31:0] sorted, sort_packed, sort_unpacked;
wire        pen15;

wire scr_hflip, scr_vflip;

assign rom_cs    = ~objcha_n | pre_cs;
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
assign pen15   = &pre_pxl[3:0];
assign pen_eff = (pre_pxl[15:14]==0 || !pen15) ? pre_pxl[3:0] : 4'd0; // real color or 0 if shadow
assign shd     =  pre_pxl[15:14];
assign prio    =  pre_pxl[13:9];
assign pxl     =  gfx_en[3] ? {pre_pxl[8:4], pen_eff} : 9'd0;

// Simpsons, X-Men
jtframe_8x8x4_packed_msb u_packed(rom_data, sort_packed);

assign sorted = PACKED==1 ? sort_packed : rom_data;

// X-Men 6P: one 053246 serves both monitors. MAME draws each monitor's
// sprites at VB start with the register values of that moment
// (xmen.cpp screen_vblank), while the CPU already programs the other
// monitor's X/Y offset during the next frame. The drawing registers
// (X offset, Y offset, cfg) are therefore latched: CPU writes go to shadows,
// applied at VB start. The ROM readback address (word 2 high, word 3) stays
// live because the CPU reads sprite ROM right after setting it (16-bit mode).
reg  [15:0] sh_x, sh_y;
reg  [ 7:0] sh_cfg;
reg  [ 1:0] rp_cnt;      // replay step: 1 X, 2 Y, 3 cfg
wire        cpu_mmr_we = reg_cs & mmr_we;
wire [ 1:0] cpu_word   = mmr_addr[2:1];
// live path: only the rmrd bytes reach the chip
wire [ 1:0] live_dsn   = cpu_word==3 ? mmr_dsn :
                         cpu_word==2 ? {mmr_dsn[1], 1'b1} : 2'b11;
reg         k46_cs, k46_we;
reg  [ 3:0] k46_addr;
reg  [15:0] k46_din;
reg  [ 1:0] k46_dsn;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        sh_x <= 0; sh_y <= 0; sh_cfg <= 0; rp_cnt <= 0;
    end else begin
        if( cpu_mmr_we ) case( cpu_word )
            0: begin
                if(!mmr_dsn[1]) sh_x[15:8] <= mmr_din[15:8];
                if(!mmr_dsn[0]) sh_x[ 7:0] <= mmr_din[ 7:0];
            end
            1: begin
                if(!mmr_dsn[1]) sh_y[15:8] <= mmr_din[15:8];
                if(!mmr_dsn[0]) sh_y[ 7:0] <= mmr_din[ 7:0];
            end
            2: if(!mmr_dsn[0]) sh_cfg <= mmr_din[7:0];
            default:;
        endcase
        if( bank_load ) rp_cnt <= 1;
        else if( rp_cnt!=0 ) rp_cnt <= rp_cnt + 2'd1;
    end
end

always @* begin
    k46_cs   = reg_cs;
    k46_we   = mmr_we;
    k46_addr = mmr_addr;
    k46_din  = mmr_din;
    k46_dsn  = live_dsn;
    if( rp_cnt!=0 ) begin   // replay has priority; a held CPU write retries next clock
        k46_cs  = 1;
        k46_we  = 1;
        case( rp_cnt )
            1: begin k46_addr = 4'b0000; k46_din = sh_x;          k46_dsn = 2'b00; end
            2: begin k46_addr = 4'b0010; k46_din = sh_y;          k46_dsn = 2'b00; end
            default: begin
                     k46_addr = 4'b0100; k46_din = {8'd0,sh_cfg}; k46_dsn = 2'b10; end
        endcase
    end
end

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
    .voffset    ( voffset   ),
    // CPU interface
    .cs         ( k46_cs    ),
    .cpu_we     ( k46_we    ),
    .cpu_addr   ( k46_addr  ),
    .cpu_dout   ( k46_din   ),
    .cpu_dsn    ( k46_dsn   ),
    .rmrd_addr  ( rmrd_addr ),

    // External RAM
    .dma_addr   ( dma_addr  ), // up to 16 kB
    .dma_data   ( dma_data  ),
    .dma_bsy    ( dma_bsy   ),

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

jtxmen6p_objdraw #(
    .SHADOW(SHADOW),.SHADOW_PEN(SHADOW_PEN),
    .AW(10),.CW(16),.PW(4+10+2),.LATCH(1),.SWAPH(1),
    .ZW(12),.ZI(6), .ZENLARGE(1),.SW(2),.FLIP_OFFSET(9'h12)
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
    .pal        ({pre_shd, attr}),

    .rom_addr   ( pre_addr      ),
    .rom_cs     ( pre_cs        ),
    .rom_ok     ( rom_ok        ),
    .rom_data   ( sorted        ),

    .pxl        ( pre_pxl       )
);

// X-Men 6P sprite list snapshot. MAME memcpy's the selected 4 kB list into
// the 053247 at VB start, before the CPU runs. In frames that draw the right
// monitor the CPU rewrites both lists right after VB start, so the 053246 DMA
// (which starts two lines later and lasts ~10 lines) raced those writes and
// the right monitor lost its sprites. The list is now copied at full speed
// into a private buffer at VB start; CPU writes to sprite RAM wait (DTACK and
// write enable held) during the 2048-clock copy. The DMA reads the snapshot.
// Both monitors of a displayed pair must use the same CPU state (see the
// scroll snapshot in jtxmen6p_k052109): at the VB start of the left monitor
// both lists are copied (left then right, 4096 clocks); the right monitor's
// frame reuses the right list copied then, so a list update in between cannot
// move sprites on one monitor only.
reg  [12:0] cp_cnt;        // {list, offset}; bit 12 set = done
reg  [11:0] cp_wa;
reg         cp_we;
// [13:1] is byte-address numbered: bit 13 selects 0x102000 (right list),
// bit 12 would select 0x101000 (a CPU scratch buffer)
wire [13:1] cp_raddr = { cp_cnt[11], 1'b0, cp_cnt[10:0] };
assign copy_busy = ~cp_cnt[12];

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cp_cnt <= 13'h1000;
        cp_we  <= 0;
        cp_wa  <= 0;
    end else begin
        cp_we <= copy_busy;        // RAM data for cp_cnt arrives next clock
        cp_wa <= cp_cnt[11:0];
        if( bank_load && !dma_bank ) cp_cnt <= 0;
        else if( copy_busy ) cp_cnt <= cp_cnt + 13'd1;
    end
end

jtframe_dual_ram #(.DW(16),.AW(12)) u_snap(
    .clk0   ( clk          ),
    .data0  ( dma_rdata    ),
    .addr0  ( cp_wa        ),
    .we0    ( cp_we        ),
    .q0     (              ),
    .clk1   ( clk          ),
    .data1  ( 16'd0        ),
    .addr1  ({ dma_bank, dma_addr[11:1] }),
    .we1    ( 1'b0         ),
    .q1     ( dma_snap     )
);

jtframe_dual_nvram16 #(
    .AW     ( RAMW    ),
    .SIMFILE("obj.bin")
) u_ram( // 8 or 16kB? check PCB. Game seems to work on 8kB ok
    // Port 0 - CPU access
    .clk0   ( clk       ),
    .data0  ( ram_din   ),
    .addr0  ( ram_addr  ),
    .we0    ( ram_we & {2{ram_cs & ~copy_busy}} ),
    .q0     ( ram_data  ),
    // Port 1 - Video access
    .clk1   ( clk       ),
    .addr1a ( cp_raddr[RAMW:1] ),
    .q1a    ( dma_rdata ),
    // 8-bit IOCTL access
    .data1  ( 8'd0      ),
    .addr1b ( ioctl_addr[RAMW:0] ),
    .we1b   ( 1'd0      ),
    .q1b    ( dump_ram  ),
    .sel_b  ( ioctl_ram )
);

// the 053247 sprite RAM is 4 kB: the second half of the DMA scan reads nothing
assign dma_raddr = cp_raddr;
assign dma_data  = dma_addr[12] ? 16'd0 : dma_snap;

endmodule