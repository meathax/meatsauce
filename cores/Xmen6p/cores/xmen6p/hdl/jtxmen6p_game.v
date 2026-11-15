/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 23-8-2024 */

module jtxmen6p_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

// localparam [2:0] XMEN     = 3'd2;

/* verilator tracing_off */
wire        snd_irq, rmrd, rst8, dma_bsy,
            pal_cs, cpu_we, tilesys_cs, objsys_cs, pcu_cs, mute, objcha_n,
            cpu_rnw, vdtac, tile_irqn, tile_nmin, snd_wrn,
            objreg_cs, pair_we;
wire [15:0] pal_dout, oram_dout;
wire [15:0] video_dumpa;
wire [13:1] oram_addr;
reg  [ 7:0] debug_mux;
// reg  [ 2:0] game_id;
// reg         xmen;
wire [ 7:0] tilesys_dout, snd2main,
            obj_dout, snd_latch, pair_dout,
            st_main, st_video, st_snd;
wire [ 1:0] oram_we, ram_dsn;
wire        ram_cs;
wire        field, tsel, nlvbl;
// character select
wire [41:0] sjoy;
wire [ 5:0] sstart_n, scoin_n;
wire [ 9:0] ovl_x;
wire [ 7:0] ovl_y;
wire [ 1:0] ovl;
reg  [ 5:0] inplay;

assign debug_view = debug_mux;
assign ram_we     = {2{cpu_we & ram_cs}} & ~ram_dsn;
assign video_dumpa= ioctl_addr[15:0]-16'h80; // subtract NVRAM offset

always @(posedge clk) begin
    debug_mux <= st_snd;
    // case( debug_bus[7:6] )
    //     0: debug_mux <= st_main;
    //     1: debug_mux <= st_video;
    //     2: debug_mux <= st_snd;
    //     3: debug_mux <= { mute, /*xmen,*/ 7'b0 };
    //     default: debug_mux <= 0;
    // endcase
end

/*always @(posedge clk) begin
    if( prog_addr[3:0]==15 && prog_we && header ) game_id <= prog_data[2:0];
    xmen     <= game_id == XMEN;
end
*/
// Slots in play: game RAM byte 11355C, bit n = slot n joined (MAME xmen6p:
// set by joining, cleared when the continue countdown ends)
always @(posedge clk, posedge rst) begin
    if( rst )
        inplay <= 0;
    else if( ram_cs && cpu_we && !ram_dsn[1] && main_addr[13:1]==13'h1AAE )
        inplay <= ram_din[13:8];
end

jtxmen6p_seats u_seats(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .joy1       ( joystick1     ),
    .joy2       ( joystick2     ),
    .joy3       ( joystick3     ),
    .joy4       ( joystick4     ),
    .joy5raw    ( joystick5     ),
    .joy6raw    ( joystick6     ),
    .start_n    ( cab_1p        ),
    .coin_n     ( coin          ),
    // character select: overlay picker only, no OSD options
    .osd_sel    ( 18'd0         ),
    .picker_en  ( 1'b1          ),
    .inplay     ( inplay        ),
    .sjoy       ( sjoy          ),
    .sstart_n   ( sstart_n      ),
    .scoin_n    ( scoin_n       ),
    .ox         ( ovl_x         ),
    .oy         ( ovl_y         ),
    .ovl        ( ovl           )
);

/* verilator tracing_on */
jtxmen6p_main u_main(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .LVBL           ( nlvbl         ),

    .cpu_we         ( cpu_we        ),
    .cpu_dout       ( ram_din       ),
    .vdtac          ( vdtac         ),
    .tile_irqn      ( tile_irqn     ),

    .main_addr      ( main_addr     ),
    .rom_data       ( main_data     ),
    .rom_cs         ( main_cs       ),
    .rom_ok         ( main_ok       ),
    // RAM
    .ram_dsn        ( ram_dsn       ),
    .ram_dout       ( ram_data      ),
    .ram_cs         ( ram_cs        ),
    // cabinet I/O
    .cab_1p         ( sstart_n      ),
    .coin           ( scoin_n       ),
    .joystick1      ( sjoy[ 6: 0]   ),
    .joystick2      ( sjoy[13: 7]   ),
    .joystick3      ( sjoy[20:14]   ),
    .joystick4      ( sjoy[27:21]   ),
    .joystick5      ( sjoy[34:28]   ),
    .joystick6      ( sjoy[41:35]   ),
    .field          ( field         ),
    .tsel           ( tsel          ),
    .service        ( {4{service}}  ),

    .vram_dout      ( tilesys_dout  ),
    .oram_dout      ( oram_dout     ),
    .pal_dout       ( pal_dout      ),
    // To video
    .rmrd           ( rmrd          ),
    .dma_bsy        ( dma_bsy       ),
    .objreg_cs      ( objreg_cs     ),
    .objcha_n       ( objcha_n      ),

    .obj_cs         ( objsys_cs     ),
    .vram_cs        ( tilesys_cs    ),
    .pal_cs         ( pal_cs        ),
    .pcu_cs         ( pcu_cs        ), // priority mixer
    // To sound
    .sndon          ( snd_irq       ),
    .snd2main       ( snd2main      ),
    .snd_wrn        ( snd_wrn       ),
    .mute           ( mute          ),
    .pair_we        ( pair_we       ),
    .pair_dout      ( pair_dout     ),
    // EEPROM
    .nv_addr        ( nvram_addr    ),
    .nv_dout        ( nvram_dout    ),
    .nv_din         ( nvram_din     ),
    .nv_we          ( nvram_we      ),
    // DIP switches
    .dip_pause      ( dip_pause     ),
    .dip_test       ( dip_test      ),
    // Debug
    .st_dout        ( st_main       ),
    .debug_bus      ( debug_bus     )
);

assign oram_we   = ~ram_dsn & {2{cpu_we}};
assign oram_addr = {main_addr[6:5], main_addr[1], main_addr[13:7], main_addr[4:2]};

/* verilator tracing_off */
jtxmen6p_video u_video (
    .rst            ( rst           ),
    .rst8           ( rst8          ),
    .clk            ( clk           ),
    .pxl_cen        ( pxl_cen       ),
    .pxl2_cen       ( pxl2_cen      ),
    .tsel           ( tsel          ),
    .field          ( field         ),
    .nlvbl          ( nlvbl         ),
    .ovl_x          ( ovl_x         ),
    .ovl_y          ( ovl_y         ),
    .ovl            ( ovl           ),

    .tile_irqn      ( tile_irqn     ),
    .tile_nmin      (               ),

    .lhbl           ( LHBL          ),
    .lvbl           ( LVBL          ),
    .hs             ( HS            ),
    .vs             ( VS            ),
    .flip           ( dip_flip      ),
    // GFX - CPU interface
    .cpu_we         ( cpu_we        ),
    .cpu_addr       (main_addr[18:1]),
    .cpu_dsn        ( ram_dsn       ),
    .cpu_dout       ( ram_din       ),

    // Object DMA
    .oram_we        ( oram_we       ),
    .oram_addr      ( oram_addr     ),
    .dma_bsy        ( dma_bsy       ),

    .objsys_cs      ( objsys_cs     ),
    .objreg_cs      ( objreg_cs     ),
    .objcha_n       ( objcha_n      ),
    .tilesys_cs     ( tilesys_cs    ),
    .pal_cs         ( pal_cs        ),
    .pcu_cs         ( pcu_cs        ),
    .vdtac          ( vdtac         ),
    .tilesys_dout   ( tilesys_dout  ),
    .objsys_dout    ( oram_dout     ),
    .pal_dout       ( pal_dout      ),
    .rmrd           ( rmrd          ),
    // SDRAM
    .lyra_addr      ( lyra_addr     ),
    .lyrb_addr      ( lyrb_addr     ),
    .lyrf_addr      ( lyrf_addr     ),
    .lyro_addr      ( lyro_addr     ),
    .lyra_data      ( lyra_data     ),
    .lyrb_data      ( lyrb_data     ),
    .lyro_data      ( lyro_data     ),
    .lyrf_data      ( lyrf_data     ),
    .lyrf_cs        ( lyrf_cs       ),
    .lyra_cs        ( lyra_cs       ),
    .lyrb_cs        ( lyrb_cs       ),
    .lyro_cs        ( lyro_cs       ),
    .lyra_ok        ( lyra_ok       ),
    .lyro_ok        ( lyro_ok       ),
    // brightness
    .dim            (  3'b0         ),
    .dimmod         (  1'b0         ),
    .dimpol         (  1'b0         ),
    // pixels
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .ioctl_addr     ( video_dumpa   ),
    .ioctl_din      ( ioctl_din     ),
    .ioctl_ram      ( ioctl_ram     ),
    .gfx_en         ( gfx_en        ),
    .st_dout        ( st_video      )
);

/* verilator tracing_on */
jtxmen6p_sound u_sound(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen_8      ( cen_8         ),
    .cen_4      ( cen_4         ),
    .cen_2      ( cen_2         ),
    .cen_pcm    ( cen_pcm       ),

    .pair_we    ( pair_we       ),
    .pair_dout  ( pair_dout     ),
    // communication with main CPU
    .main_dout  ( ram_din[7:0]  ),
    .main_din   ( snd2main      ),
    .main_addr  ( main_addr[4:1]),
    .main_rnw   ( snd_wrn       ),
    .snd_irq    ( snd_irq       ),
    // ROM
    .rom_addr   ( snd_addr      ),
    .rom_cs     ( snd_cs        ),
    .rom_data   ( snd_data      ),
    .rom_ok     ( snd_ok        ),
    // ADPCM ROM
    .pcm_addr   ( pcm_addr      ),
    .pcm_dout   ( pcm_data      ),
    .pcm_cs     ( pcm_cs        ),
    .pcm_ok     ( pcm_ok        ),
    // Sound output
    .k539_l     ( k539_l        ),
    .k539_r     ( k539_r        ),
    // Debug
    .debug_bus  ( debug_bus     ),
    .st_dout    ( st_snd        )
);

endmodule
