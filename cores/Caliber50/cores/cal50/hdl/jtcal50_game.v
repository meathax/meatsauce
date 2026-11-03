/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 14-11-2025 */

module jtcal50_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

wire [13:1] cpu_addr;
wire [ 1:0] cpu_dsn;
wire [ 8:0] hdump;
wire [ 7:0] snd_cmd, snd_rply, st_main, st_snd, st_video;
wire [15:0] vram_dout;
wire        set_cmd, flip, cpu_rnw, cen244, snd_rst,
            vram_cs, vctrl_cs, vflag_cs, pal_cs, tctrl_cs;

assign debug_view = debug_bus[7] ? st_snd : st_video;
assign dip_flip   = ~flip;

wire [1:0] aim_dial1, aim_dial2, aim_fire, aim_owned;
wire [1:0] aim_step, aim_dir, aim_write;
wire [3:0] aim_data;
wire aim_dial_reset;
wire [5:0] aim_joy1 = {joystick1[5], joystick1[4] & ~aim_fire[0], joystick1[3:0]};
wire [5:0] aim_joy2 = {joystick2[5], joystick2[4] & ~aim_fire[1], joystick2[3:0]};

caliber_aim_controls #(.CLOCK_HZ(`JTFRAME_MCLK)) u_aim(
    .clk(clk), .reset(rst), .paused(~dip_pause), .dial_reset(aim_dial_reset),
    .unrotated(status[2]), .right1(joyana_r1), .right2(joyana_r2),
    .legacy1(dial_x), .legacy2(dial_y), .speed(status[21:20]),
    .deadzone(status[24:23]), .autofire(status[22]),
    .angle_write(aim_write), .angle_data(aim_data),
    .decoder_step(aim_step), .decoder_dir(aim_dir),
    .dial1(aim_dial1), .dial2(aim_dial2), .fire(aim_fire), .owned(aim_owned)
);

/* verilator tracing_on */
jtcal50_main u_main(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .pxl_cen        ( pxl_cen       ),
    .cen244         ( cen244        ),
    .lvbl           ( LVBL          ),
    .hdump          ( hdump[1:0]    ),

    .tctrl_cs       ( tctrl_cs      ),
    .vctrl_cs       ( vctrl_cs      ),
    .vflag_cs       ( vflag_cs      ),
    .vram_cs        ( vram_cs       ),
    .vram_dout      ( vram_dout     ),

    .cpu_rnw        ( cpu_rnw       ),
    .cpu_dout       ( cpu_dout      ),

    .cpu_addr       ( cpu_addr      ),
    .cpu_dsn        ( cpu_dsn       ),
    .ram_addr       ( ram_addr      ),
    .rom_addr       ( main_addr     ),
    .rom_data       ( main_data     ),
    .rom_cs         ( main_cs       ),
    .rom_ok         ( main_ok       ),
    // NVRAM
    .nvram_we       ( nvram_we      ),
    .nvram_dout     ( nvram_dout    ),
    // RAM
    .ram_we         ( ram_we        ),
    .ram_dout       ( ram_dout      ),
    // cabinet I/O
    .cab_1p         ( cab_1p[1:0]   ),
    .coin           ( coin[1:0]     ),
    .joystick1      ( aim_joy1      ),
    .joystick2      ( aim_joy2      ),
    .dial_x         ( aim_dial1     ),
    .dial_y         ( aim_dial2     ),
    .score_pause    ( score_pause   ),
    .score_idle     ( score_idle    ),
    .dial_reset     ( aim_dial_reset),
    .dial_x_step    ( aim_step[0]   ),
    .dial_y_step    ( aim_step[1]   ),
    .dial_x_dir     ( aim_dir[0]    ),
    .dial_y_dir     ( aim_dir[1]    ),
    .aim1_write     ( aim_write[0]  ),
    .aim2_write     ( aim_write[1]  ),
    .aim_write_data ( aim_data      ),
    .service        ( service       ),
    .tilt           ( tilt          ),
    // video
    .pal_we         ( pal_we        ),
    .pal_dout       ( pal_dout      ),
    .tlv_we         ( tlv_we        ),
    .tlv_dout       ( tlv_dout      ),

    // Sound
    .snd_rst        ( snd_rst       ),
    .snd_cmd        ( snd_cmd       ),
    .snd_rply       ( snd_rply      ),
    .set_cmd        ( set_cmd       ),
    // DIP switches
    .dipsw          ( dipsw[15:0]   ),
    .dip_pause      ( dip_pause     ),
    .dip_test       ( dip_test      ),
    // Debug
    .st_dout        ( st_main       ),
    .debug_bus      ( debug_bus     )
);
/* verilator tracing_on */
jtcal50_sound u_sound(
    .rst            ( snd_rst       ),
    .clk            ( clk           ),
    .cen8           ( cen8          ),
    .cen244         ( cen244        ),
    .cen_pcm        ( cen_pcm       ),

    // communication with main CPU
    .snd_cmd        ( snd_cmd       ),
    .snd_rply       ( snd_rply      ),
    .set_cmd        ( set_cmd       ),
    // ROM
    .rom_addr       ( snd_addr      ),
    .rom_cs         ( snd_cs        ),
    .rom_data       ( snd_data      ),
    .rom_ok         ( snd_ok        ),
    // PCM ROM
    .pcm_addr       ( pcm_addr      ),
    .pcm_data       ( pcm_data      ),
    .pcm_cs         ( pcm_cs        ),
    // Sound
    .snd_left       ( pcm_8k        ),
    .snd_right      ( pcm_4k        ),
    .mute           ( mute          ),
    // Debug
    .debug_bus      ( debug_bus     ),
    .st_dout        ( st_snd        )
);
/* verilator tracing_on */
jtcal50_video u_video(
    .rst            ( rst           ),
    .clk            ( clk           ),
    .clk_cpu        ( clk           ),
    .cen244         ( cen244        ),

    .pxl2_cen       ( pxl2_cen      ),
    .pxl_cen        ( pxl_cen       ),
    .LHBL           ( LHBL          ),
    .LVBL           ( LVBL          ),
    .HS             ( HS            ),
    .VS             ( VS            ),
    .hdump          ( hdump         ),
    .flip           ( flip          ),
    .thoffs         ( flip ? 16'h20 : 16'h1e1 ),
    .obj_hshift     ( 9'd0          ),
    // GFX - CPU interface
    .cpu_rnw        ( cpu_rnw       ),
    .cpu_dsn        ( cpu_dsn       ),
    .cpu_addr       ( cpu_addr      ),
    .cpu_dout       ( cpu_dout      ),

    .vram_cs        ( vram_cs       ),
    .vctrl_cs       ( vctrl_cs      ),
    .vflag_cs       ( vflag_cs      ),
    .vram_dout      ( vram_dout     ),

    // X1-001 Internal RAM
    .col_addr       ( col_addr      ),
    .col_data       ( col_data      ),
    .yram_dout      ( yram_dout     ),
    .yram_we        ( yram_we       ),

    // X1-001 External VRAM
    .dma_addr       ( dma_addr      ),
    .dma_din        ( dma_din       ),
    .dma_we         ( dma_we        ),
    .dma_dout       ( dma_dout      ),
    .code_dout      ( code_dout     ),
    .code_addr      ( code_addr     ),

    // Tilemap X1-012
    .tctrl_cs       ( tctrl_cs      ),
    .tvram_addr     ( tlrd_addr     ),
    .tvram_dout     ( tlrd_data     ),
    .tile_addr      ( tile_addr     ),
    .tile_data      ( tile_data     ),
    .tile_cs        ( tile_cs       ),
    .tile_ok        ( tile_ok       ),

    .pal_addr       ( palrd_addr    ),
    .pal_data       ( pal_data      ),

    // SDRAM
    .scr_addr       ( scr_addr      ),
    .scr_data       ( scr_data      ),
    .scr_ok         ( scr_ok        ),
    .scr_cs         ( scr_cs        ),

    .obj_addr       ( obj_addr      ),
    .obj_data       ( obj_data      ),
    .obj_ok         ( obj_ok        ),
    .obj_cs         ( obj_cs        ),
    // pixels
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
    // IOCTL dump
    .ioctl_addr     (ioctl_addr[3:0]),
    .ioctl_din      ( ioctl_din     ),
    // Test
    .gfx_en         ( gfx_en        ),
    .debug_bus      ( debug_bus     ),
    .st_dout        ( st_video      )
);

endmodule
