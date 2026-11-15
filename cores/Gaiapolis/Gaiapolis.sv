`include "gaiapolis_mister_config.vh"
//============================================================================
//  JTFRAME by Jose Tejada Gomez. Twitter: @topapate
//
//  Port to MiSTer
//  Thanks to Sorgelig for his continuous support
//  Original repository: http://github.com/jotego/jt_gng
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

`ifdef JTFRAME_VERTICAL
`define JTFRAME_MR_DDR
`endif

`ifdef JTFRAME_LF_BUFFER
`define JTFRAME_MR_DDR
`endif

`ifdef JTFRAME_MR_DDRLOAD
`define JTFRAME_MR_DDR
`endif

module emu(
    `include "sys/emu_ports.vh"
);
localparam SDRAMW=23; // Same real controller geometry as native.

wire   crt_f1;      // CRT portrait 480i field
`ifndef JTFRAME_INTERLACED
assign VGA_F1=crt_f1;
`else
wire   field;
assign VGA_F1=field;
`endif

`ifndef MISTER_FB_PALETTE
wire FB_PAL_CLK,FB_PAL_WR;
wire [7:0] FB_PAL_ADDR;
wire [23:0] FB_PAL_DOUT;
wire [23:0] FB_PAL_DIN=24'd0;
`endif
// unused features
assign ADC_BUS='z;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;
gaiapolis_mister_audio_mix u_audio_mix(.sound_mono(dipsw[4]), .audio_mix(AUDIO_MIX));
assign BUTTONS       = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;

wire db15_en,uart_en,gun_border_en,show_osd;
wire [1:0] dial_x, dial_y;

////////////////////   CLOCKS   ///////////////////

wire clk_sys, clk_rom, clk96, clk96sh, clk48, clk48sh, clk24;
wire game_rst, game_service, game_tilt, rst, rst_n;
wire clk_pico;
wire pxl2_cen, pxl_cen;
wire rst96, rst48, rst24;
wire pll_locked;
wire pll_rst;
wire sys_rst;
`ifdef JTFRAME_PLL_TUNE
wire [63:0] pll_reconfig_to, pll_reconfig_from;
wire        pll_cfg_waitrequest, pll_cfg_write, pll_tune_hold;
wire [ 5:0] pll_cfg_address;
wire [31:0] pll_cfg_writedata;
`endif

// Resets the PLL if it looses lock
jtframe_sync u_sync(
    .clk_in     ( CLK_50M   ),
    .clk_out    ( clk_sys   ),
    .raw        ( RESET     ),
    .sync       ( sys_rst   )
);

`ifndef JTFRAME_PLL_TUNE
gaiapolis_mister_pll_watchdog u_pll_watchdog(
    .clk_ref(CLK_50M), .reset_async(RESET),
    .pll_locked(pll_locked), .pll_reset(pll_rst)
);
`else
assign pll_rst = 1'b0;
`endif

// There are many false paths defined in the
// SDC file between this PLL and the ones
// used in sys_top
gaiapolis_mister_pll pll(
    .refclk     ( CLK_50M    ),
    .rst        ( pll_rst    ),
    .locked     ( pll_locked ),
    .outclk_0   ( clk48      ),
    .outclk_1   ( clk48sh    ),
    .outclk_2   ( clk24      ),
    .outclk_3   (            ),
    .outclk_4   ( clk96      ),
    .outclk_5   ( clk96sh    )
`ifdef JTFRAME_PLL_TUNE
   ,.reconfig_to_pll   ( pll_reconfig_to   ),
    .reconfig_from_pll ( pll_reconfig_from )
`endif
);

jtframe_rst_sync u_reset96(
    .rst        ( game_rst  ),
    .clk        ( clk96     ),
    .rst_sync   ( rst96     )
);

jtframe_rst_sync u_reset48(
    .rst        ( game_rst  ),
    .clk        ( clk48     ),
    .rst_sync   ( rst48     )
);

jtframe_rst_sync u_reset24(
    .rst        ( game_rst  ),
    .clk        ( clk24     ),
    .rst_sync   ( rst24     )
);

`ifdef JTFRAME_SDRAM96
    assign clk_rom = clk96;
    assign clk_sys = clk96;
`else
    assign clk_rom = clk48;
    assign clk_sys = clk48;
`endif

assign clk_pico = clk48;

generate
    if( `JTFRAME_180SHIFT == 0 ) begin
        // Forward the real phase through the I/O DDR clock cell. Ordinary
        // fabric-to-pad clock forwarding adds an avoidable return-path delay.
        altddio_out #(.width(1),.intended_device_family("Cyclone V"),
                      .power_up_high("OFF")) sdramclk_phase(
            .datain_h(1'b1),.datain_l(1'b0),
        `ifdef JTFRAME_SDRAM96
            .outclock(clk96sh),
        `else
            .outclock(clk48sh),
        `endif
            .dataout(SDRAM_CLK),.aclr(1'b0),.aset(1'b0),.oe(1'b1),
            .outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
    end else begin
        altddio_out
        #(
            .extend_oe_disable("OFF"),
            .intended_device_family("Cyclone V"),
            .invert_output("OFF"),
            .lpm_hint("UNUSED"),
            .lpm_type("altddio_out"),
            .oe_reg("UNREGISTERED"),
            .power_up_high("OFF"),
            .width(1)
        )
        sdramclk_ddr
        (
            .datain_h(1'b0),
            .datain_l(1'b1),
            .outclock(clk_rom),
            .dataout(SDRAM_CLK),
            .aclr(1'b0),
            .aset(1'b0),
            .oe(1'b1),
            .outclocken(1'b1),
            .sclr(1'b0),
            .sset(1'b0)
        );
    end
endgenerate

///////////////////////////////////////////////////

wire [63:0] status;
wire [ 1:0] buttons;

`ifdef JTFRAME_PLL_TUNE
pll_cfg_hdmi pll_game_cfg(
    .mgmt_clk        ( CLK_50M            ),
    .mgmt_reset      ( RESET              ),
    .mgmt_waitrequest( pll_cfg_waitrequest ),
    .mgmt_write      ( pll_cfg_write       ),
    .mgmt_address    ( pll_cfg_address     ),
    .mgmt_writedata  ( pll_cfg_writedata   ),
    .reconfig_to_pll ( pll_reconfig_to     ),
    .reconfig_from_pll(pll_reconfig_from   )
);

jtframe_pll_tune pll_tune(
    .clk            ( CLK_50M            ),
    .rst            ( RESET              ),
    .speed          ( status[15:13]      ),
    .pll_locked     ( pll_locked          ),
    .cfg_waitrequest( pll_cfg_waitrequest ),
    .cfg_write      ( pll_cfg_write       ),
    .cfg_address    ( pll_cfg_address     ),
    .cfg_writedata  ( pll_cfg_writedata   ),
    .hold_reset     ( pll_tune_hold       )
);
`endif

wire [ 1:0] dip_fxlevel;
wire        dip_pause, dip_flip, dip_test;
wire        direct_flip;
wire [31:0] dipsw;

wire        ioctl_wr;
wire [26:0] ioctl_addr; // up to 128MB
wire [ 7:0] ioctl_dout, ioctl_din;

wire [ 9:0] game_joy1, game_joy2, game_joy3, game_joy4;
wire [ 3:0] game_coin, game_start;
wire [ 3:0] gfx_en;
wire [ 7:0] debug_bus, debug_view;
wire [15:0] joyana_l1, joyana_l2, joyana_l3, joyana_l4,
            joyana_r1, joyana_r2, joyana_r3, joyana_r4;

wire        rst_req   = sys_rst | status[0] | buttons[1]
`ifdef JTFRAME_PLL_TUNE
                        | pll_tune_hold
`endif
                        ;
wire [15:0] snd_left, snd_right;
wire [ 5:0] snd_en, snd_vu;
wire [ 7:0] snd_vol;
wire        snd_peak;

assign LED_DISK  = 2'b0;
assign LED_POWER = 2'b0;

// ROM download
wire          ioctl_rom, ioctl_cart, dwnld_busy;

wire [SDRAMW-1:0] prog_addr;
wire [15:0]   prog_data;
wire [ 1:0]   prog_mask, prog_ba;
wire          prog_we, prog_rd, prog_rdy, prog_ack, prog_dst, prog_dok;

wire [21:0] game_ba0,game_ba1,game_ba2,game_ba3,game_prog_addr;
assign ba0_addr={1'b0,game_ba0};
assign ba1_addr={1'b0,game_ba1};
assign ba2_addr={1'b0,game_ba2};
assign ba3_addr={1'b0,game_ba3};
assign prog_addr={1'b0,game_prog_addr};

// ROM access from game
wire [SDRAMW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [ 3:0] ba_rd, ba_rdy, ba_ack, ba_dst, ba_dok, ba_wr;
wire [15:0] ba0_din, ba1_din, ba2_din, ba3_din;
wire [ 1:0] ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
`ifdef JTFRAME_SDRAM_CACHE
wire [SDRAMW-1:0] burst_addr;
wire [ 1:0] burst_ba;
wire        burst_rd, burst_wr, burst_ack, burst_dst, burst_dok, burst_rdy;
wire [15:0] burst_din;
`endif
wire [15:0] sdram_dout;

wire [ 7:0] st_addr, st_dout;
wire [8:0] spinner_1,spinner_2,spinner_3,spinner_4;
wire [7:0] paddle_1,paddle_2,paddle_3,paddle_4;
wire [15:0] mouse_1p, mouse_2p;
wire [ 1:0] mouse_strobe;
wire [ 8:0] gun_1p_x, gun_1p_y, gun_2p_x, gun_2p_y;

localparam COLORW=`JTFRAME_COLORW;

wire [COLORW-1:0] red, green, blue;
wire              LHBL, LVBL;
wire              hs, vs, sample;
wire              ioctl_ram;
wire              game_rx, game_tx;

`ifndef JTFRAME_UART
    assign game_tx = 1;
`endif

`ifndef JTFRAME_SIGNED_SND
assign AUDIO_S = 1'b1; // Assume signed by default
`else
assign AUDIO_S = `JTFRAME_SIGNED_SND;
`endif

// Line-Frame buffer
`ifndef JTFRAME_LF_BUFFER
assign {game_vrender,game_hdump,ln_addr,ln_data,ln_done,ln_we,fb_keep}='0;
`endif
wire [`JTFRAME_LF_HW-1:0] game_hdump,   ln_addr;
wire [`JTFRAME_LF_VW-1:0] game_vrender, ln_v;
wire        ln_done, ln_hs, ln_vs, ln_lvbl, ln_we, fb_keep;
wire [15:0] ln_dout, ln_pxl, ln_data;

gaiapolis_mister_platform #(
    .SDRAMW         ( SDRAMW         ),
    .BUTTONS        (`JTFRAME_BUTTONS),
    .COLORW         ( COLORW         ),
    .VIDEO_WIDTH    (`JTFRAME_WIDTH  ),
    .VIDEO_HEIGHT   (`JTFRAME_HEIGHT )
)
u_frame(
    .clk_sys        ( clk_sys        ),
    .clk_rom        ( clk_rom        ),
    .clk_pico       ( clk_pico       ),
    .pll_locked     ( pll_locked     ),
    // interface with microcontroller
    .status         ( status         ),
    .HPS_BUS        ( HPS_BUS        ),
    .buttons        ( buttons        ),
    // Extension port (fake USB3)
    .USER_OUT       ( USER_OUT       ),
    .USER_IN        ( USER_IN        ),
    .db15_en        ( db15_en        ),
    .uart_en        ( uart_en        ),
    .game_rx        ( game_rx        ), // core-specific UART
    .game_tx        ( game_tx        ),
    .show_osd       ( show_osd       ),
    .OSD_STATUS     ( OSD_STATUS     ),
    // Base video
    .game_r         ( red            ),
    .game_g         ( green          ),
    .game_b         ( blue           ),
    .LHBL           ( LHBL           ),
    .LVBL           ( LVBL           ),
    .hs             ( hs             ),
    .vs             ( vs             ),
    .pxl_cen        ( pxl_cen        ),
    .pxl2_cen       ( pxl2_cen       ),

    // Audio
    .snd_lin        ( snd_left       ),
    .snd_rin        ( snd_right      ),
    .snd_sample     ( sample         ),
    .snd_rout       ( AUDIO_R        ),
    .snd_lout       ( AUDIO_L        ),
    .snd_en         ( snd_en         ),
    .snd_vu         ( snd_vu         ),
    .snd_vol        ( snd_vol        ),
    .snd_peak       ( snd_peak       ),
    // line-frame buffer
    .game_vrender   ( game_vrender   ),
    .game_hdump     ( game_hdump     ),
    .ln_addr        ( ln_addr        ),
    .ln_data        ( ln_data        ),
    .ln_done        ( ln_done        ),
    .ln_hs          ( ln_hs          ),
    .ln_dout        ( ln_dout        ),
    .ln_pxl         ( ln_pxl         ),
    .ln_v           ( ln_v           ),
    .ln_vs          ( ln_vs          ),
    .ln_lvbl        ( ln_lvbl        ),
    .ln_we          ( ln_we          ),
    .fb_keep        ( fb_keep        ),
`ifdef JTFRAME_LF_ZOOM
    .game_h_step    ( game_h_step    ),
    .game_v_step    ( game_v_step    ),
`endif

    `ifdef JTFRAME_VERTICAL
    // Screen rotation
    .FB_EN          ( FB_EN          ),
    .FB_FORMAT      ( FB_FORMAT      ),
    .FB_WIDTH       ( FB_WIDTH       ),
    .FB_HEIGHT      ( FB_HEIGHT      ),
    .FB_BASE        ( FB_BASE        ),
    .FB_STRIDE      ( FB_STRIDE      ),
    .FB_VBL         ( FB_VBL         ),
    .FB_LL          ( FB_LL          ),
    .FB_FORCE_BLANK ( FB_FORCE_BLANK ),

    .FB_PAL_CLK     ( FB_PAL_CLK     ),
    .FB_PAL_ADDR    ( FB_PAL_ADDR    ),
    .FB_PAL_DOUT    ( FB_PAL_DOUT    ),
    .FB_PAL_DIN     ( FB_PAL_DIN     ),
    .FB_PAL_WR      ( FB_PAL_WR      ),
    `endif

    // DDR interface
    .DDRAM_CLK      ( DDRAM_CLK      ), // same as clk_rom
    .DDRAM_BURSTCNT ( DDRAM_BURSTCNT ),
    .DDRAM_ADDR     ( DDRAM_ADDR     ),
    .DDRAM_BE       ( DDRAM_BE       ),
    .DDRAM_WE       ( DDRAM_WE       ),
    .DDRAM_BUSY     ( DDRAM_BUSY     ),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY ),
    .DDRAM_DOUT     ( DDRAM_DOUT     ),
    .DDRAM_RD       ( DDRAM_RD       ),
    .DDRAM_DIN      ( DDRAM_DIN      ),

    // SDRAM interface
    .SDRAM_CLK      ( SDRAM_CLK      ),
    .SDRAM_DQ       ( SDRAM_DQ       ),
    .SDRAM_A        ( SDRAM_A        ),
    .SDRAM_DQML     ( SDRAM_DQML     ),
    .SDRAM_DQMH     ( SDRAM_DQMH     ),
    .SDRAM_nWE      ( SDRAM_nWE      ),
    .SDRAM_nCAS     ( SDRAM_nCAS     ),
    .SDRAM_nRAS     ( SDRAM_nRAS     ),
    .SDRAM_nCS      ( SDRAM_nCS      ),
    .SDRAM_BA       ( SDRAM_BA       ),
    .SDRAM_CKE      ( SDRAM_CKE      ),
    // ROM access from game
    .ba0_addr   ( ba0_addr      ),
    .ba1_addr   ( ba1_addr      ),
    .ba2_addr   ( ba2_addr      ),
    .ba3_addr   ( ba3_addr      ),
`ifdef JTFRAME_SDRAM_CACHE
    .burst_addr ( burst_addr    ),
    .burst_ba   ( burst_ba      ),
    .burst_rd   ( burst_rd      ),
    .burst_wr   ( burst_wr      ),
    .burst_ack  ( burst_ack     ),
    .burst_dst  ( burst_dst     ),
    .burst_dok  ( burst_dok     ),
    .burst_rdy  ( burst_rdy     ),
`endif
    .ba_rd      ( ba_rd         ),
    .ba_wr      ( ba_wr         ),
    .ba_dst     ( ba_dst        ),
    .ba_dok     ( ba_dok        ),
    .ba_rdy     ( ba_rdy        ),
    .ba_ack     ( ba_ack        ),
    .ba0_din    ( ba0_din       ),
    .ba0_dsn    ( ba0_dsn       ),
    .ba1_din    ( ba1_din       ),
    .ba1_dsn    ( ba1_dsn       ),
    .ba2_din    ( ba2_din       ),
    .ba2_dsn    ( ba2_dsn       ),
    .ba3_din    ( ba3_din       ),
    .ba3_dsn    ( ba3_dsn       ),
`ifdef JTFRAME_SDRAM_CACHE
    .burst_din  ( burst_din     ),
`endif

    // ROM-load interface
    .prog_addr  ( prog_addr     ),
    .prog_ba    ( prog_ba       ),
    .prog_rd    ( prog_rd       ),
    .prog_we    ( prog_we       ),
    .prog_data  ( prog_data     ),
    .prog_mask  ( prog_mask     ),
    .prog_ack   ( prog_ack      ),
    .prog_dst   ( prog_dst      ),
    .prog_dok   ( prog_dok      ),
    .prog_rdy   ( prog_rdy      ),

    .sdram_dout     ( sdram_dout     ),

    // ROM load
    .ioctl_addr     ( ioctl_addr     ),
    .ioctl_dout     ( ioctl_dout     ),
    .ioctl_wr       ( ioctl_wr       ),
    .ioctl_ram      ( ioctl_ram      ),
    .ioctl_din      ( ioctl_din      ),

    .ioctl_rom      ( ioctl_rom      ),
    .ioctl_cart     ( ioctl_cart     ),
    .dwnld_busy     ( dwnld_busy     ),
    // Save/Load
    .sav_change     ( sav_change     ),
    .sav_wait       ( sav_wait       ),
    .sav_done       ( sav_done       ),
    .sav_wr         ( sav_wr         ),
    .sav_ack        ( sav_ack        ),
    .sav_din        ( sav_din        ),
    .sav_dout       ( sav_dout       ),
    .sav_addr       ( sav_addr       ),
//////////// board
    .rst            ( rst            ),
    .rst_n          ( rst_n          ), // unused
    .game_rst       ( game_rst       ),
    .game_rst_n     (                ),
    // reset forcing signals:
    .rst_req        ( rst_req        ),
    // joystick
    .game_joystick1 ( game_joy1      ),
    .game_joystick2 ( game_joy2      ),
    .game_joystick3 ( game_joy3      ),
    .game_joystick4 ( game_joy4      ),
    .game_coin      ( game_coin      ),
    .game_start     ( game_start     ),
    .game_service   ( game_service   ),
    .game_tilt      ( game_tilt      ),
    .joyana_l1      ( joyana_l1      ),
    .joyana_l2      ( joyana_l2      ),
    .joyana_l3      ( joyana_l3      ),
    .joyana_l4      ( joyana_l4      ),
    .joyana_r1      ( joyana_r1      ),
    .joyana_r2      ( joyana_r2      ),
    .joyana_r3      ( joyana_r3      ),
    .joyana_r4      ( joyana_r4      ),
    // Paddle inputs
    .game_paddle_1  ( paddle_1       ),
    .game_paddle_2  ( paddle_2       ),
    .game_paddle_3  ( paddle_3       ),
    .game_paddle_4  ( paddle_4       ),
    .spinner_1      ( spinner_1      ),
    .spinner_2      ( spinner_2      ),
    .spinner_3      ( spinner_3      ),
    .spinner_4      ( spinner_4      ),
    // Mouse inputs
    .mouse_1p       ( mouse_1p       ),
    .mouse_2p       ( mouse_2p       ),
    .mouse_strobe   ( mouse_strobe   ),
    .LED            ( LED_USER       ),
    // Dial emulation
    .dial_x         ( dial_x         ),
    .dial_y         ( dial_y         ),
    // Lightguns
    .gun_1p_x       ( gun_1p_x       ),
    .gun_1p_y       ( gun_1p_y       ),
    .gun_2p_x       ( gun_2p_x       ),
    .gun_2p_y       ( gun_2p_y       ),
    .gun_border_en  ( gun_border_en  ),
    // DIP and OSD settings
    .dip_test       ( dip_test       ),
    .dip_pause      ( dip_pause      ),
    .dip_flip       ( dip_flip       ),
    .dip_fxlevel    ( dip_fxlevel    ),
    .dipsw          ( dipsw          ),
    .direct_flip    ( direct_flip    ),
    // screen
    .rotate         (                ),
    // HDMI
    .hdmi_arx       ( VIDEO_ARX      ),
    .hdmi_ary       ( VIDEO_ARY      ),
    .hdmi_width     ( HDMI_WIDTH     ),
    .hdmi_height    ( HDMI_HEIGHT    ),
    // scan doubler output to VGA pins
    .scan2x_r       ( VGA_R          ),
    .scan2x_g       ( VGA_G          ),
    .scan2x_b       ( VGA_B          ),
    .scan2x_hs      ( VGA_HS         ),
    .scan2x_vs      ( VGA_VS         ),
    .scan2x_clk     ( CLK_VIDEO      ),
    .scan2x_cen     ( CE_PIXEL       ),
    .scan2x_de      ( VGA_DE         ),
    .crt_interlaced ( crt_f1         ),
    .scan2x_sl      ( VGA_SL         ),
    // status
    .st_addr        ( st_addr        ),
    .st_dout        ( st_dout        ),
    // Debug
    .gfx_en         ( gfx_en         ),
    .debug_bus      ( debug_bus      ),
    .debug_view     ( debug_view     )
);

/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 14-1-2023 */

// Game instantiation. Shared by all target top-level modules


`ifndef JTFRAME_STATUS
assign st_dout=8'd0;
`endif
`ifndef JTFRAME_SAVEGAME
assign {sav_change,sav_wait,sav_done,sav_din}='0;
`endif

localparam STARTW=4;

wire [16:0]  sram_addr;
wire [15:0]  sram_din, sram_dout;
wire [ 1:0]  sram_dsn;
wire         sram_wen, sram_ok;

wire [15:0]  sav_din, sav_dout, sav_addr;
wire         sav_change, sav_wait, sav_done, sav_ack;
wire [ 1:0]  sav_wr;

`ifdef JTFRAME_LF_ZOOM
wire [ 8:0]  game_h_step, game_v_step;
`endif

`ifdef SIMULATION
assign sim_hb         = ~LHBL;
assign sim_vb         = ~LVBL;
assign sim_pxl_clk    = clk_sys;
assign sim_pxl_cen    = pxl_cen;
assign sim_dwnld_busy = dwnld_busy;

`ifdef TESTINPUTS
    test_inputs u_test_inputs(
        .loop_rst       ( ioctl_rom      ),
        .LVBL           ( LVBL           ),
        .game_joystick1 ( game_joy1[6:0] ),
        .button_1p      ( game_start[0]  ),
        .coin_left      ( game_coin[0]   )
    );
    assign game_start[1] = 1'b1;
    assign game_coin[1]  = 1'b1;
    assign game_joystick2 = ~10'd0;
    assign game_joystick3 = ~10'd0;
    assign game_joystick4 = ~10'd0;
    assign game_joystick1[9:7] = 3'b111;
    assign sim_vb = vs;
    assign sim_hb = hs;
`endif
// For simulation, either ~32'd0 or `JTFRAME_SIM_DIPS will be used for DIPs
`ifndef JTFRAME_SIM_DIPS
    `define JTFRAME_SIM_DIPS 32'hffffffef
`endif
`endif

jtgaiapolis_game_sdram
u_game(
    .rst         ( game_rst       ),
    // The main clock is always the same one as the SDRAM
    .clk         ( clk_rom        ),
    .clk96       ( clk96          ),
    .rst96       ( rst96          ), `ifdef JTFRAME_CLK48
    .clk48       ( clk48          ),
    .rst48       ( rst48          ), `endif
    .clk24       ( clk24          ),
    .rst24       ( rst24          ),
    // Video
    .pxl2_cen    ( pxl2_cen       ),
    .pxl_cen     ( pxl_cen        ),
    .red         ( red            ),
    .green       ( green          ),
    .blue        ( blue           ),
    .LHBL        ( LHBL           ),
    .LVBL        ( LVBL           ),
    .HS          ( hs             ),
    .VS          ( vs             ), `ifdef JTFRAME_INTERLACED
    .field       ( field          ), `endif

    // Inputs
    .cab_1p ( game_start[STARTW-1:0]      ), .coin ( game_coin[STARTW-1:0]       ),
    .joystick1    ( game_joy1[`JTFRAME_BUTTONS+3:0] ), .joystick2  ( game_joy2[`JTFRAME_BUTTONS+3:0] ),
    .joystick3    ( game_joy3[`JTFRAME_BUTTONS+3:0] ), .joystick4  ( game_joy4[`JTFRAME_BUTTONS+3:0] ), `ifdef JTFRAME_PADDLE
    .paddle_0     ( paddle_1         ), .paddle_1     ( paddle_2         ),
    .paddle_2     ( paddle_3         ), .paddle_3     ( paddle_4         ), `endif `ifdef JTFRAME_MOUSE
    .mouse_1p     ( mouse_1p         ), .mouse_2p     ( mouse_2p         ), .mouse_strobe ( mouse_strobe ), `endif `ifdef JTFRAME_LIGHTGUN
    .gun_1p_x     ( gun_1p_x         ), .gun_1p_y     ( gun_1p_y         ),
    .gun_2p_x     ( gun_2p_x         ), .gun_2p_y     ( gun_2p_y         ), `endif `ifdef JTFRAME_SPINNER
    .spinner_1p   ( spinner_1p       ), .spinner_2p   ( spinner_2p       ), `endif
    .joyana_l1    ( joyana_l1        ), .joyana_l2    ( joyana_l2        ),
    .joyana_l3    ( joyana_l3        ), .joyana_l4    ( joyana_l4        ),
    .joyana_r1    ( joyana_r1        ), .joyana_r2    ( joyana_r2        ),
    .joyana_r3    ( joyana_r3        ), .joyana_r4    ( joyana_r4        ),
    .dial_x       ( dial_x           ), .dial_y       ( dial_y           ),
    // PROM programming
    .ioctl_addr  ( ioctl_addr[25:0]     ),
    .ioctl_dout  ( ioctl_dout     ),
    .ioctl_cart  ( ioctl_cart     ),
    .ioctl_wr    ( ioctl_wr       ),
    .ioctl_ram   ( ioctl_ram      ), `ifdef JTFRAME_IOCTL_RD
    .ioctl_din   ( ioctl_din      ), `endif
    // ROM load
    .ioctl_rom   ( ioctl_rom      ),
    .dwnld_busy  ( dwnld_busy     ),
    .data_read   ( sdram_dout     ),

    `ifdef JTFRAME_LF_BUFFER
    // line-frame buffer
    .game_vrender ( game_vrender     ),
    .game_hdump   ( game_hdump       ),
    .ln_addr      ( ln_addr          ),
    .ln_data      ( ln_data          ),
    .ln_done      ( ln_done          ),
    .ln_hs        ( ln_hs            ),
    .ln_dout      ( ln_dout          ),
    .ln_pxl       ( ln_pxl           ),
    .ln_v         ( ln_v             ),
    .ln_vs        ( ln_vs            ),
    .ln_lvbl      ( ln_lvbl          ),
    .ln_we        ( ln_we            ),
    .fb_keep      ( fb_keep          ), `endif

`ifdef JTFRAME_LF_ZOOM
    .h_step       ( game_h_step      ),
    .v_step       ( game_v_step      ), `endif

    // Bank 0: allows R/W
    .ba0_addr   ( game_ba0      ),
    .ba1_addr   ( game_ba1      ),
    .ba2_addr   ( game_ba2      ),
    .ba3_addr   ( game_ba3      ),
`ifdef JTFRAME_SDRAM_CACHE
    .burst_addr ( burst_addr    ),
    .burst_ba   ( burst_ba      ),
    .burst_rd   ( burst_rd      ),
    .burst_wr   ( burst_wr      ),
`endif
    .ba_rd      ( ba_rd         ),
    .ba_wr      ( ba_wr         ),
    .ba_dst     ( ba_dst        ),
    .ba_dok     ( ba_dok        ),
    .ba_rdy     ( ba_rdy        ),
    .ba_ack     ( ba_ack        ),
`ifdef JTFRAME_SDRAM_CACHE
    .burst_dst  ( burst_dst     ),
    .burst_dok  ( burst_dok     ),
    .burst_rdy  ( burst_rdy     ),
    .burst_ack  ( burst_ack     ),
`endif
    .ba0_din    ( ba0_din       ),
    .ba0_dsn    ( ba0_dsn       ),
    .ba1_din    ( ba1_din       ),
    .ba1_dsn    ( ba1_dsn       ),
    .ba2_din    ( ba2_din       ),
    .ba2_dsn    ( ba2_dsn       ),
    .ba3_din    ( ba3_din       ),
    .ba3_dsn    ( ba3_dsn       ),
`ifdef JTFRAME_SDRAM_CACHE
    .burst_din  ( burst_din     ),
`endif

    .prog_ba    ( prog_ba       ),
    .prog_rdy   ( prog_rdy      ),
    .prog_ack   ( prog_ack      ),
    .prog_dok   ( prog_dok      ),
    .prog_dst   ( prog_dst      ),
    .prog_data  ( prog_data     ),

`ifdef JTFRAME_SRAM
    // SRAM
    .sram_addr  ( sram_addr     ),
    .sram_din   ( sram_din      ),
    .sram_dout  ( sram_dout     ),
    .sram_wen   ( sram_wen      ),
    .sram_dsn   ( sram_dsn      ),
    .sram_ok    ( sram_ok       ),
`endif

`ifdef JTFRAME_SAVEGAME
    // Save/Load
    .sav_change ( sav_change    ),
    .sav_wait   ( sav_wait      ),
    .sav_done   ( sav_done      ),
    .sav_wr     ( sav_wr        ),
    .sav_ack    ( sav_ack       ),
    .sav_din    ( sav_din       ),
    .sav_dout   ( sav_dout      ),
    .sav_addr   ( sav_addr      ),
`endif
    // common ROM-load interface
    .prog_addr  ( game_prog_addr     ),
    .prog_rd    ( prog_rd       ),
    .prog_we    ( prog_we       ),
    .prog_mask  ( prog_mask     ),

    // DIP switches
    .status      ( status[31:0]   ),
    .dip_pause   ( dip_pause      ),
    .dip_flip    ( dip_flip       ),
    .dip_test    ( dip_test       ),
    .dip_fxlevel ( dip_fxlevel    ),
    .service     ( game_service   ),
    .tilt        ( game_tilt      ),
    .dipsw       ( dipsw ^ {26'd0,direct_flip,5'd0} ),

`ifdef JTFRAME_GAME_UART
    .uart_tx     ( game_tx        ),
    .uart_rx     ( game_rx        ), `endif
    // sound
`ifndef JTFRAME_STEREO
    .snd         ( snd_left       ),
`else
    .snd_left    ( snd_left       ),
    .snd_right   ( snd_right      ),
`endif
    .sample      ( sample         ),
    .snd_en      ( snd_en         ),
    .snd_vol     ( snd_vol        ),
    .snd_vu      ( snd_vu         ),
    .snd_peak    ( snd_peak       ),
    // Debug
`ifdef JTFRAME_STATUS
    .st_addr     ( st_addr        ),
    .st_dout     ( st_dout        ), `endif
    .gfx_en      ( gfx_en         ),
    .debug_bus   ( debug_bus      ),
    .debug_view  ( debug_view     )
);


`ifndef JTFRAME_STEREO
    assign snd_right = snd_left;
`endif

endmodule
