/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 28-1-2020 */

module jtcps1_game(
    `include "jtframe_game_ports.inc" // see $JTFRAME/hdl/inc/jtframe_game_ports.inc
);

wire        clk_gfx, rst_gfx, hold_rst;
wire        snd_cs, adpcm_cs, main_ram_cs, main_vram_cs, main_rom_cs,
            rom0_cs, rom1_cs,
            vram_dma_cs;
wire [ 1:0] joymode;
wire [15:0] snd_addr;
wire [17:0] adpcm_addr;
wire [ 7:0] snd_data, adpcm_data;
wire [17:1] ram_addr;
wire [21:1] main_rom_addr;
wire [15:0] main_ram_data, main_rom_data, main_dout, mmr_dout;
wire        main_rom_ok, main_ram_ok;
wire        ppu1_cs, ppu2_cs, ppu_rstn;
wire [19:0] rom1_addr, rom0_addr;
wire [31:0] rom0_data, rom1_data;
// Video RAM interface
wire [17:1] vram_dma_addr;
wire [15:0] vram_dma_data;
wire        vram_dma_ok, rom0_ok, rom1_ok, snd_ok, adpcm_ok;
wire [15:0] cpu_dout;
wire        cpu_speed;
wire        star_bank, dump_flag;

wire        main_rnw, busreq, busack;
wire [ 7:0] snd_latch0, snd_latch1;
wire [ 7:0] dipsw_a, dipsw_b, dipsw_c;

wire [12:0] star0_addr, star1_addr;
wire [31:0] star0_data, star1_data;
wire        star0_ok,   star1_ok,
            star0_cs,   star1_cs;

wire        vram_clr, vram_rfsh_en;
wire [ 8:0] hdump;
wire [ 8:0] vdump, vrender;

wire        rom0_half, rom1_half;
wire        cfg_we;

`ifdef FW_TWINSTICK
wire [ 9:0] fw_joy1, fw_joy2;
wire [ 7:0] fw_joy1_aim, fw_joy2_aim;
wire [ 1:0] fw_dial_x, fw_dial_y, fw_fire, fw_owned;
wire [ 1:0] fw_aim_write, fw_counter_cleared;
wire [15:0] fw_acc_data;
wire        fw_score_pause, fw_score_idle, fw_score_owner;
wire        fw_ram_cs, fw_ram_we;
wire [16:0] fw_ram_addr;
wire [15:0] fw_ram_din;
wire [ 7:0] fw_score_din, fw_sdram_ioctl_din;
`endif

// EEPROM
wire        sclk, sdi, sdo, scs;

assign { dipsw_c, dipsw_b, dipsw_a } = dipsw[23:0];

wire [15:0] fave;
wire [ 1:0] dsn;
wire        cen10b;
wire        cpu_cen, cpu_cenb;
wire        charger;
wire        turbo, video_flip, filter_old;
reg         rst_game;

`include "turbo.vh"
assign snd_vu       = 0;
assign filter_old   = dipsw[24];
assign debug_view   = debug_bus[0] ? fave[7:0] : fave[15:8];
    //{ 6'd0, dump_flag, filter_old };
assign ba1_din=0, ba2_din=0, ba3_din=0,
       ba1_dsn=3, ba2_dsn=3, ba3_dsn=3;

assign clk_gfx  = clk;
assign rst_gfx  = rst;

always @(posedge clk) rst_game <= hold_rst | rst48;

localparam REGSIZE=24;

`ifdef FW_TWINSTICK
// Twin-stick aiming: status[19:18] aim speed, status[20] autofire, status[28:27] deadzone.
assign fw_joy1 = { joystick1[9:8], fw_joy1_aim };
assign fw_joy2 = { joystick2[9:8], fw_joy2_aim };
forgotten_aim_controls #(.CLOCK_HZ(48000000)) u_aim(
    .clk( clk48 ), .reset( rst_game ), .paused( ~dip_pause ),
    .left1( joyana_l1 ), .left2( joyana_l2 ), .right1( joyana_r1 ), .right2( joyana_r2 ),
    .legacy1( dial_x ), .legacy2( dial_y ),
    .speed( status[19:18] ), .deadzone( status[28:27] ), .autofire( status[20] ),
    .joy1( joystick1[7:0] ), .joy2( joystick2[7:0] ),
    .acc_write( fw_aim_write ), .acc_data( main_dout ), .counter_cleared( fw_counter_cleared ),
    .joy1_out( fw_joy1_aim ), .joy2_out( fw_joy2_aim ),
    .dial1( fw_dial_x ), .dial2( fw_dial_y ), .fire( fw_fire ), .owned( fw_owned )
);
`endif

// Turbo speed disables DMA
wire busreq_cpu = busreq & ~turbo;
wire busack_cpu;
assign busack = busack_cpu | turbo;
/* verilator tracing_on */
jtcps1_main u_main(
    .rst        ( rst_game          ),
    .clk        ( clk48             ),
    .cen10      ( cpu_cen           ),
    .cen10b     ( cpu_cenb          ),
    .cpu_cen    (                   ),
    .turbo      ( turbo             ),
    .joymode    ( joymode           ),
    // Timing
    .V          ( vdump             ),
    .LVBL       ( LVBL              ),
    .LHBL       ( LHBL              ),
    // PPU
    .ppu1_cs    ( ppu1_cs           ),
    .ppu2_cs    ( ppu2_cs           ),
    .ppu_rstn   ( ppu_rstn          ),
    .mmr_dout   ( mmr_dout          ),
    // Sound
    .snd_latch0 ( snd_latch0        ),
    .snd_latch1 ( snd_latch1        ),
    .UDSWn      ( dsn[1]            ),
    .LDSWn      ( dsn[0]            ),
    // cabinet I/O
    // Cabinet input
    .charger     ( charger          ),
    .cab_1p      ( cab_1p[1:0]      ),
    .coin        ( coin[1:0]        ),
`ifdef FW_TWINSTICK
    .joystick1   ( fw_joy1          ),
    .joystick2   ( fw_joy2          ),
    .dial_x      ( fw_dial_x        ),
    .dial_y      ( fw_dial_y        ),
`else
    .joystick1   ( joystick1        ),
    .joystick2   ( joystick2        ),
    .dial_x      ( dial_x           ),
    .dial_y      ( dial_y           ),
`endif
    .service     ( service          ),
    .tilt        ( 1'b1             ),
    // BUS sharing
    .busreq      ( busreq_cpu       ),
    .busack      ( busack_cpu       ),
    .RnW         ( main_rnw         ),
    // RAM/VRAM access
    .addr        ( ram_addr         ),
    .cpu_dout    ( main_dout        ),
    .ram_cs      ( main_ram_cs      ),
    .vram_cs     ( main_vram_cs     ),
    .ram_data    ( main_ram_data    ),
    .ram_ok      ( main_ram_ok      ),
    // ROM access
    .rom_cs      ( main_rom_cs      ),
    .rom_addr    ( main_rom_addr    ),
    .rom_data    ( main_rom_data    ),
    .rom_ok      ( main_rom_ok      ),
    // DIP switches
    .dip_pause   ( dip_pause        ),
    .dip_test    ( dip_test         ),
    .dipsw_a     ( dipsw_a          ),
    .dipsw_b     ( dipsw_b          ),
    .dipsw_c     ( dipsw_c          ),
`ifdef FW_TWINSTICK
    .score_pause ( fw_score_pause   ),
    .score_idle  ( fw_score_idle    ),
    .aim_write   ( fw_aim_write     ),
    .counter_cleared( fw_counter_cleared ),
`endif
    .fave        ( fave             )
);

`ifdef FW_TWINSTICK
// OSD-triggered score persistence borrows SDRAM slot 0 while the CPU is halted and idle.
forgotten_score u_score(
    .clk( clk ), .reset( rst_game ), .osd_status( score_osd ),
    .host_download( score_host_download ), .host_upload( score_host_upload ),
    .host_ram( ioctl_ram ), .host_wr( ioctl_wr ), .host_addr( ioctl_addr ),
    .host_dout( ioctl_dout ), .host_din( fw_score_din ),
    .cpu_idle( fw_score_idle ), .pause_request( fw_score_pause ), .ram_owner( fw_score_owner ),
    .ram_cs( fw_ram_cs ), .ram_we( fw_ram_we ), .ram_addr( fw_ram_addr ), .ram_din( fw_ram_din ),
    .ram_ok( main_ram_ok ), .ram_dout( main_ram_data ), .upload_request( score_upload_request )
);
assign ioctl_din = fw_score_din;
wire        sd_main_ram_cs = fw_score_owner ? fw_ram_cs   : main_ram_cs;
wire        sd_main_rnw    = fw_score_owner ? ~fw_ram_we  : main_rnw;
wire [ 1:0] sd_dsn         = fw_score_owner ? 2'b00       : dsn;
wire [15:0] sd_main_dout   = fw_score_owner ? fw_ram_din  : main_dout;
wire [17:1] sd_ram_addr    = fw_score_owner ? fw_ram_addr : ram_addr;
`endif

reg rst_video;

always @(posedge clk_gfx) begin
    rst_video <= rst_gfx;
end

assign dip_flip = video_flip;
/* verilator tracing_off */
jtcps1_video #(REGSIZE) u_video(
    .rst            ( rst_video     ),
    .clk            ( clk_gfx       ),
    .clk_cpu        ( clk48         ),
    .pxl2_cen       ( pxl2_cen      ),
    .pxl_cen        ( pxl_cen       ),

    .hdump          ( hdump         ),
    .vdump          ( vdump         ),
    .vrender        ( vrender       ),
    .gfx_en         ( gfx_en        ),
    .cpu_speed      ( cpu_speed     ),
    .charger        ( charger       ),
    .kabuki_en      (               ),
    .raster         (               ),
    .watch          (               ),
    .watch_vram_cs  (               ),
    .star_bank      ( star_bank     ),

    // CPU interface
    .ppu_rstn       ( ppu_rstn      ),
    .ppu1_cs        ( ppu1_cs       ),
    .ppu2_cs        ( ppu2_cs       ),
    .addr           ( ram_addr[12:1]),
    .dsn            ( dsn           ),      // data select, active low
    .cpu_dout       ( main_dout     ),
    .mmr_dout       ( mmr_dout      ),
    // BUS sharing
    .busreq         ( busreq        ),
    .busack         ( busack        ),

    // Video signal
    .HS             ( HS            ),
    .VS             ( VS            ),
    .LHBL           ( LHBL          ),
    .LVBL           ( LVBL          ),
    .red            ( red           ),
    .green          ( green         ),
    .blue           ( blue          ),
    .flip           ( video_flip    ),

    // CPS-B Registers
    .cfg_we         ( cfg_we        ),
    .cfg_data       ( prog_data[7:0]),

    // EEPROM
    .sclk           ( sclk          ),
    .sdi            ( sdi           ),
    .sdo            ( sdo           ),
    .scs            ( scs           ),

    // Extra inputs read through the C-Board
    .cab_1p   ( cab_1p  ),
    .coin     ( coin    ),
    .joystick1      ( joystick1     ),
    .joystick2      ( joystick2     ),
    .joystick3      ( joystick3     ),
    .joystick4      ( joystick4     ),

    // Video RAM interface
    .vram_dma_addr  ( vram_dma_addr ),
    .vram_dma_data  ( vram_dma_data ),
    .vram_dma_ok    ( vram_dma_ok   ),
    .vram_dma_cs    ( vram_dma_cs   ),
    .vram_dma_clr   ( vram_clr      ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    // GFX ROM interface
    .rom1_addr      ( rom1_addr     ),
    .rom1_half      ( rom1_half     ),
    .rom1_data      ( rom1_data     ),
    .rom1_cs        ( rom1_cs       ),
    .rom1_ok        ( rom1_ok       ),
    .rom0_addr      ( rom0_addr     ),
    .rom0_bank      (               ),
    .rom0_half      ( rom0_half     ),
    .rom0_data      ( rom0_data     ),
    .rom0_cs        ( rom0_cs       ),
    .rom0_ok        ( rom0_ok       ),

    .star0_addr     ( star0_addr    ),
    .star0_data     ( star0_data    ),
    .star0_ok       ( star0_ok      ),
    .star0_cs       ( star0_cs      ),

    .star1_addr     ( star1_addr    ),
    .star1_data     ( star1_data    ),
    .star1_ok       ( star1_ok      ),
    .star1_cs       ( star1_cs      ),
    .debug_bus      ( debug_bus     )
);

`ifdef FAKE_LATCH
integer snd_frame_cnt=0;
reg [7:0] fake_latch0 = 8'h0, fake_latch1 = 8'h0;
assign snd_latch1 = fake_latch1;
assign snd_latch0 = fake_latch0;
localparam FAKE0=20;
localparam FAKE1=1000;
always @(negedge LVBL) begin
    snd_frame_cnt <= snd_frame_cnt+1;
    case( snd_frame_cnt )
        /* ffight
        FAKE0: fake_latch <= 8'hf0;
        FAKE0+5+2: fake_latch <= 8'hf7;
        FAKE0+5+4: fake_latch <= 8'hf2;
        FAKE0+5+6: fake_latch <= 8'h55;
        default: fake_latch <= 8'hff;
        */
        // Nemo
        //FAKE0: fake_latch <= 8'h2;
        //FAKE0+1: fake_latch <= 8'h2;
        //FAKE0+2: fake_latch <= 8'h0;
        // KOD
        FAKE0: fake_latch0 <= 8'h6;
        // Magic Sword
        //FAKE0: fake_latch <= 8'h1e;
        //FAKE1: fake_latch <= 8'h0;
        //FAKE1+1: fake_latch <= 8'h4;
        //FAKE1+2: fake_latch <= 8'h0;
        // SF2, Chun Li
        // FAKE0: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hf0;
        // end

        // FAKE0+10: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end
        // FAKE0+11: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hf7;
        // end
        // FAKE0+12: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end
        // FAKE0+13: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'h06;
        // end
        // FAKE0+14: begin
        //     fake_latch1 <= 8'h00;
        //     fake_latch0 <= 8'hff;
        // end

        //default: fake_latch <= 8'hff;
    endcase
end
`endif

reg [3:0] rst_snd;
always @(posedge clk) begin
    rst_snd <= { rst_snd[2:0], rst_game };
end
/* verilator tracing_off */
jtcps1_sound u_sound(
    .rst            ( rst_snd[3]    ),
    .clk            ( clk48         ),

    .filter_old     ( filter_old    ),
    .dip_fxlevel    ( dip_fxlevel   ),
    // Interface with main CPU
    .snd_latch0     ( snd_latch0    ),
    .snd_latch1     ( snd_latch1    ),

    // ROM
    .rom_addr       ( snd_addr      ),
    .rom_cs         ( snd_cs        ),
    .rom_data       ( snd_data      ),
    .rom_ok         ( snd_ok        ),

    // ADPCM ROM
    .adpcm_addr     ( adpcm_addr    ),
    .adpcm_cs       ( adpcm_cs      ),
    .adpcm_data     ( adpcm_data    ),
    .adpcm_ok       ( adpcm_ok      ),

    // Sound output
    .left           ( snd_left      ),
    .right          ( snd_right     ),
    .sample         ( sample        ),
    .peak           ( snd_peak      ),
    .debug_bus      ( debug_bus     )
);

reg rst_sdram;
always @(posedge clk) rst_sdram <= rst;

wire nc0, nc1, nc2, nc3;
/* verilator tracing_on */
jtcps1_sdram #(.REGSIZE(REGSIZE)) u_sdram (
    .rst         ( rst_sdram     ),
    .clk         ( clk           ),
    .clk_gfx     ( clk_gfx       ),
    .clk_cpu     ( clk48         ),
    .LVBL        ( LVBL          ),
    .star_bank   ( star_bank     ),
    .hold_rst    ( hold_rst      ),

    .ioctl_rom   ( ioctl_rom     ),
    .dwnld_busy  ( dwnld_busy    ),
    .cfg_we      ( cfg_we        ),

    // ROM LOAD
    .ioctl_addr  ( ioctl_addr    ),
    .ioctl_dout  ( ioctl_dout    ),
`ifdef FW_TWINSTICK
    .ioctl_din   ( fw_sdram_ioctl_din ),
`else
    .ioctl_din   ( ioctl_din     ),
`endif
    .ioctl_wr    ( ioctl_wr      ),
    .ioctl_ram   ( ioctl_ram     ),
    /*verilator lint_off width*/
    .prog_addr   ( prog_addr     ),
    /*verilator lint_on width*/
    .prog_data   ( prog_data     ),
    .prog_mask   ( prog_mask     ),
    .prog_ba     ( prog_ba       ),
    .prog_we     ( prog_we       ),
    .prog_rd     ( prog_rd       ),
    .prog_rdy    ( prog_rdy      ),
    // Unused QSound ports
    .prog_qsnd   (               ),
    .kabuki_we   (               ),
    // Unused CPS2 ports
    .cps2_key_we (               ),
    .cps2_joymode( joymode       ),
    .rom0_bank   (               ),

    // EEPROM
    .sclk           ( sclk          ),
    .sdi            ( sdi           ),
    .sdo            ( sdo           ),
    .scs            ( scs           ),

    // Main CPU
    .main_rom_cs    ( main_rom_cs   ),
    .main_rom_ok    ( main_rom_ok   ),
    .main_rom_addr  ( main_rom_addr ),
    .main_rom_data  ( main_rom_data ),

    // VRAM
    .vram_clr       ( vram_clr      ),
    .vram_dma_cs    ( vram_dma_cs   ),
`ifdef FW_TWINSTICK
    .main_ram_cs    ( sd_main_ram_cs ),
`else
    .main_ram_cs    ( main_ram_cs   ),
`endif
    .main_vram_cs   ( main_vram_cs  ),
    .vram_rfsh_en   ( vram_rfsh_en  ),

    // Object RAM (CPS2)
    .main_oram_cs   ( 1'b0          ),

`ifdef FW_TWINSTICK
    .dsn            ( sd_dsn         ),
    .main_dout      ( sd_main_dout   ),
    .main_rnw       ( sd_main_rnw    ),
`else
    .dsn            ( dsn           ),
    .main_dout      ( main_dout     ),
    .main_rnw       ( main_rnw      ),
`endif

    .main_ram_ok    ( main_ram_ok   ),
    .vram_dma_ok    ( vram_dma_ok   ),

`ifdef FW_TWINSTICK
    .main_ram_addr  ( sd_ram_addr    ),
`else
    .main_ram_addr  ( ram_addr      ),
`endif
    .vram_dma_addr  ( vram_dma_addr ),

    .main_ram_data  ( main_ram_data ),
    .vram_dma_data  ( vram_dma_data ),

    // Sound CPU and PCM
    .snd_cs      ( snd_cs        ),
    .pcm_cs      ( adpcm_cs      ),

    .snd_ok      ( snd_ok        ),
    .pcm_ok      ( adpcm_ok      ),

    .snd_addr    ( snd_addr      ),
    .pcm_addr    ( adpcm_addr    ),

    .snd_data    ( snd_data      ),
    .pcm_data    ( adpcm_data    ),

    // Graphics
    .rom0_cs     ( rom0_cs       ),
    .rom1_cs     ( rom1_cs       ),

    .rom0_ok     ( rom0_ok       ),
    .rom1_ok     ( rom1_ok       ),

    .rom0_addr   ( rom0_addr     ),
    .rom1_addr   ( rom1_addr     ),

    .rom0_half   ( rom0_half     ),
    .rom1_half   ( rom1_half     ),

    .rom0_data   ( rom0_data     ),
    .rom1_data   ( rom1_data     ),

    .star0_addr  ( star0_addr    ),
    .star0_data  ( star0_data    ),
    .star0_ok    ( star0_ok      ),
    .star0_cs    ( star0_cs      ),

    .star1_addr  ( star1_addr    ),
    .star1_data  ( star1_data    ),
    .star1_ok    ( star1_ok      ),
    .star1_cs    ( star1_cs      ),

    // Bank 0: allows R/W
    /*verilator lint_off width*/
    .ba0_addr    ({nc0,ba0_addr} ),
    .ba1_addr    ({nc1,ba1_addr} ),
    .ba2_addr    ({nc2,ba2_addr} ),
    .ba3_addr    ({nc3,ba3_addr} ),
    /*verilator lint_on width*/
    .ba_rd       ( ba_rd         ),
    .ba_wr       ( ba_wr         ),
    .ba_ack      ( ba_ack        ),
    .ba_dst      ( ba_dst        ),
    .ba_dok      ( ba_dok        ),
    .ba_rdy      ( ba_rdy        ),
    .ba0_din     ( ba0_din       ),
    .ba0_dsn     ( ba0_dsn       ),

    .data_read   ( data_read     ),
    .dump_flag   ( dump_flag     )
);

endmodule
