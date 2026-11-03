//============================================================================
//  Action Hollywood (TCH / Proyesel 1995, MAME actionhw) - MiSTer arcade core
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  Clocking (docs/CONTRACTS.md, clock_plan.json): clk_sys == clk_video == 47.95395 MHz = 6 x 7.99233 MHz pixel,
//  SDRAM controller 95.9079 MHz (2 x clk_sys) from the same PLL; 68000 12 MHz / OKI 1 MHz are exact n/m CEs inside the game.
//  Raster: 512 x 260 total (15.612 kHz / 60.038 Hz = refresh measured on real PCB footage), active 352 x 240.
//============================================================================

module emu #(
 // Native CRT/direct-video raster (matches rtl/ah_video.sv): 6 clock pixels, 512x260, active x82..433 / y0..239,
 // HS 450..489 high, VS lines 246..248 high.  Pixel clock is an unmeasured assumption (plan.md).
 parameter integer NATIVE_PIXEL_DIV=6,NATIVE_HTOTAL=512,NATIVE_VTOTAL=260,
 // OSD ranges: H-Size 0,+1,-2,-1 (+2 does not fit the 512-clock-wide line); H-Position/V-Shift -16..+15.
 parameter integer CRT_HSIZE_MIN=-2,CRT_HSIZE_MAX=1,CRT_HPOS_MIN=-16,CRT_HPOS_MAX=15,CRT_VPOS_MIN=-16,CRT_VPOS_MAX=15
)(
    `include "sys/emu_ports.vh"
);

///////////////////////////////////////////////////////////////////////////////////// clocks / resets
wire clk_sys, clk_sdram, pll_locked;
ah_pll clock_source(.refclk(CLK_50M), .rst(RESET), .clk(clk_sys), .clk96(clk_sdram),
                    .sdram_clk(SDRAM_CLK), .locked(pll_locked));

wire [127:0] status;
wire [1:0]   buttons;
`include "build_id.v"
`include "rtl/crt/ah_crt_menu.vh"
localparam CONF_STR = {
    "AH;;",
    "P1,Video Settings;",
    "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "H1P1O[45:44],Rotation,Normal,90 CW,90 CCW,180;",
    "H2P1O[53],Rotation,Normal,180;",
    "H1P1O[47:46],Scaling,Normal,V-Integer,HV-Integer;",
    "H0P1O[52:50],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "H3P1-;",
    "H3P1O[54],CRT Adjust,Off,On;",
    "H3H4P1O[59:55],CRT H-Size,",CRT_HSIZE_OPTIONS,";",
    "H3H4P1O[66:60],CRT H-Position,",CRT_HPOS_OPTIONS,";",
    "H3H4P1O[71:67],CRT V-Shift,",CRT_VPOS_OPTIONS,";",
    "P2,Game Settings;",
    "P2O[41],OSD Pause,Off,On;",
    "P2O[42],Autosave EEPROM + Scores,On,Off;",
    "P2O[43],Audio Filter,On,Off;",
    "P2O[40],Debug Page,Off,On;",
    "P2O[38:37],SDRAM Capture,Pos4,Pos5,Pos3,Pos6;",
    "-;",
    "R[120],Credits;",
    "R[0],Reset;",
    "J1,Stun,Start,Coin,Pause,Service,Run;",
    "jn,A,Start,Select,R,L,B;",
    "v,1;V,v",`BUILD_DATE
};

wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire        forced_scandoubler, direct_video;
wire        ioctl_download, ioctl_upload, ioctl_wr;
wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
wire [26:0] ioctl_addr;
wire        ioctl_wait;
wire        upload_req, hs_upload_req, hs_configured;
wire [15:0] hs_tail_din;
wire        video_rotated;
wire        crt_available_w = 1'b1;   // CRT Adjust is valid for the native raster in both video paths
wire        sync_qualified = 1'b1;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
    .clk_sys, .HPS_BUS, .EXT_BUS(), .gamma_bus,
    .status, .buttons,
    .status_menumask({11'd0, !status[54], !(crt_available_w && CRT_MENU_RANGES_VALID), !direct_video, direct_video, direct_video}),
    .video_rotated(video_rotated),
    .joystick_0, .joystick_1, .ps2_key, .forced_scandoubler, .direct_video,
    .ioctl_download, .ioctl_upload, .ioctl_index, .ioctl_addr, .ioctl_dout, .ioctl_wr, .ioctl_rd(),
    .ioctl_wait, .ioctl_din,
    .ioctl_upload_req(upload_req), .ioctl_upload_index(8'd4)
);

wire power_reset = RESET || !pll_locked;
reg [3:0] rst_sh = 4'hf;
wire game_rst_req;
always @(posedge clk_sys or posedge power_reset)
    if (power_reset) rst_sh <= 4'hf;
    else rst_sh <= {rst_sh[2:0], game_rst_req};
wire game_rst = rst_sh[3];
wire sdram_ready;
assign game_rst_req = status[0] || buttons[1] || ioctl_download || !sdram_ready;

///////////////////////////////////////////////////////////////////////////////////// inputs
// keyboard (MiSTer PS/2 map): P1 arrows + Ctrl/Alt, P2 R/F/D/G + RCtrl/RAlt
reg [31:0] key_p1, key_p2;
reg key_pause, key_service, key_toggle;
always @(posedge clk_sys) begin
    if (game_rst) begin key_p1 <= 0; key_p2 <= 0; key_pause <= 0; key_service <= 0; key_toggle <= ps2_key[10]; end
    else if (key_toggle != ps2_key[10]) begin
        key_toggle <= ps2_key[10];
        case (ps2_key[7:0])
            8'h75: key_p1[3] <= ps2_key[9];                          // up
            8'h72: key_p1[2] <= ps2_key[9];                          // down
            8'h6b: key_p1[1] <= ps2_key[9];                          // left
            8'h74: key_p1[0] <= ps2_key[9];                          // right
            8'h14: if (ps2_key[8]) key_p2[4] <= ps2_key[9]; else key_p1[4] <= ps2_key[9];   // ctrl = Stun
            8'h11: if (ps2_key[8]) key_p2[9] <= ps2_key[9]; else key_p1[9] <= ps2_key[9];   // alt = Run
            8'h16: key_p1[5] <= ps2_key[9];                          // 1  start 1
            8'h1e: key_p2[5] <= ps2_key[9];                          // 2  start 2
            8'h2e: key_p1[6] <= ps2_key[9];                          // 5  coin 1
            8'h36: key_p2[6] <= ps2_key[9];                          // 6  coin 2
            8'h2d: key_p2[3] <= ps2_key[9];                          // R  p2 up
            8'h2b: key_p2[2] <= ps2_key[9];                          // F  p2 down
            8'h23: key_p2[1] <= ps2_key[9];                          // D  p2 left
            8'h34: key_p2[0] <= ps2_key[9];                          // G  p2 right
            8'h4d: key_pause <= ps2_key[9];                          // P
            8'h06: key_service <= ps2_key[9];                        // F2
            default: ;
        endcase
    end
end
wire [31:0] joy_p1 = joystick_0 | key_p1;
wire [31:0] joy_p2 = joystick_1 | key_p2;
// joystick bits: 0 right,1 left,2 down,3 up,4 Stun,5 Start,6 Coin,7 Pause,8 Service,9 Run.
// Run is appended so existing controller assignments retain their bit positions.
// Game BUTTON2 (P1 bit5 / P2 bit13) repeats the movement step while held; see docs/CONTROLS.md.
wire service = joy_p1[8] | joy_p2[8] | key_service;
// MAME layout, active low: P1_P2 bits 0..6 / 8..14 (right,left,down,up,b1,b2,b3), SYSTEM coin1/2 @8/9, service @11, start1/2 @12/13
wire [15:0] p1p2_n  = ~{2'b00, joy_p2[9], joy_p2[4], joy_p2[3], joy_p2[2], joy_p2[1], joy_p2[0],
                        2'b00, joy_p1[9], joy_p1[4], joy_p1[3], joy_p1[2], joy_p1[1], joy_p1[0]};
wire [15:0] system_n = ~{2'b00, joy_p2[5], joy_p1[5], service, 1'b0, joy_p2[6], joy_p1[6], 8'd0};

// pause: toggle button or OSD pause; applied at once (ah_main/ah_sound stop their CEs)
wire pause_button = joy_p1[7] | joy_p2[7] | key_pause;
reg pause_old, user_pause;
always @(posedge clk_sys) begin
    pause_old <= pause_button;
    if (game_rst) user_pause <= 0;
    else if (pause_button && !pause_old) user_pause <= !user_pause;
end
// credits_active (same clk_sys domain) pauses the game while the Credits panel is on screen; the raster keeps running.
wire credits_active;
wire pause = user_pause | (OSD_STATUS & status[41]) | credits_active;

///////////////////////////////////////////////////////////////////////////////////// loader + SDRAM
wire        wr_req, wr_ack;
wire [21:0] wr_addr;
wire [15:0] wr_data;
wire  [5:0] nv_addr;
wire [15:0] nv_din, nv_dout;
wire        nv_we;
wire        rom_active, dl_busy;
ah_loader loader(
    .clk(clk_sys), .rst(power_reset),
    .ioctl_download, .ioctl_upload, .ioctl_wr, .ioctl_index, .ioctl_addr, .ioctl_dout,
    .ioctl_wait, .ioctl_din, .sdram_ready,
    .wr_req, .wr_addr, .wr_data, .wr_ack,
    .nv_addr, .nv_din, .nv_we, .nv_dout, .hs_din(hs_tail_din), .rom_active, .busy(dl_busy)
);
// Autosave (OSD open): ONE nvram file, MRA <nvram index="4" size="168">: EEPROM (bytes 0..127, ah_loader) + hiscore
// table (bytes 128..167, ah_hiscore/hiscore.sv, standard config index 3).  ah_hiscore issues the upload request
// (after it extracted the scores while the 68000 is frozen, or as a plain EEPROM save when scores are unchanged).
assign upload_req = hs_upload_req;

wire        rom_req, gfx_req, oki_req, rom_ack, gfx_ack, oki_ack;
wire [22:2] rom_addr, gfx_addr, oki_addr;
wire [31:0] rom_data, gfx_data, oki_data;
wire [15:0] dq_out;
wire [15:0] dq_oe;
genvar dqi;
generate for (dqi = 0; dqi < 16; dqi = dqi + 1) begin : dq_pad
    assign SDRAM_DQ[dqi] = dq_oe[dqi] ? dq_out[dqi] : 1'bz;
end endgenerate
ah_sdram sdram(
    .clk96(clk_sdram), .clk48(clk_sys), .run(pll_locked), .ready(sdram_ready),
    .SDRAM_A, .SDRAM_BA, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_nCS, .SDRAM_CKE,
    .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_nWE,
    .dq_in(SDRAM_DQ), .dq_out, .dq_oe,
    .gfx_req, .gfx_addr, .gfx_ack, .gfx_data,
    .rom_req, .rom_addr, .rom_ack, .rom_data,
    .oki_req, .oki_addr, .oki_ack, .oki_data,
    .wr_req, .wr_addr, .wr_data, .wr_ack,
    .cap_sel(status[38:37])
);

///////////////////////////////////////////////////////////////////////////////////// game
wire ce_pix, hs, vs, hblank, vblank;
wire [7:0] r_g, g_g, b_g;
wire [9:0] dbg_x, dbg_y;
wire [32*13-1:0] game_words;
wire signed [15:0] game_audio;
wire flip_180 = direct_video ? status[53] : (status[45:44] == 2'd3);
ah_game game(
    .clk(clk_sys), .rst(game_rst), .pause(pause), .flip(flip_180),
    .p1p2_n, .system_n,
    .nv_addr, .nv_din, .nv_we, .nv_dout,
    .rom_req, .rom_addr, .rom_ack, .rom_data,
    .gfx_req, .gfx_addr, .gfx_ack, .gfx_data,
    .oki_req, .oki_addr, .oki_ack, .oki_data,
    .ce_pix, .hs, .vs, .hblank, .vblank, .r(r_g), .g(g_g), .b(b_g),
    .audio(game_audio), .dbg_x(dbg_x), .dbg_y(dbg_y), .dbg_words(game_words),
    .hs_osd_status(OSD_STATUS), .hs_autosave(!status[42]),
    .hs_ioctl_download(ioctl_download), .hs_ioctl_upload(ioctl_upload), .hs_ioctl_wr(ioctl_wr),
    .hs_ioctl_index(ioctl_index[7:0]), .hs_ioctl_addr(ioctl_addr), .hs_ioctl_dout(ioctl_dout),
    .hs_tail_din(hs_tail_din), .hs_upload_req(hs_upload_req), .hs_configured(hs_configured)
);

// ---- hardware debug page (OSD Game Settings -> Debug Page): rows 0/1 come from the framework, 2..12 from the game
reg [31:0] ld_words = 32'd0;
reg dl_seen = 1'b0;
always @(posedge clk_sys) begin
    if (wr_ack) ld_words <= ld_words + 32'd1;
    if (ioctl_download) dl_seen <= 1'b1;
end
wire [31:0] dbg_flags = {24'd0, status[38:37], pll_locked, pause, dl_seen, ioctl_download, sdram_ready, game_rst};
wire dbg_pix;
ah_dbg_osd dbg_osd(.clk(clk_sys), .x(dbg_x), .y(dbg_y), .words({game_words[32*13-1:64], ld_words, dbg_flags}), .pix(dbg_pix));
wire dbg_on = status[40];
wire [7:0] r = (dbg_on && dbg_pix) ? 8'hFF : r_g;
wire [7:0] g = (dbg_on && dbg_pix) ? 8'hFF : g_g;
wire [7:0] b = (dbg_on && dbg_pix) ? 8'hFF : b_g;

// ---- Credits (OSD "Credits"): MeatCore overlay on the native 352x240 raster, before CRT Adjust and rotation.
// All RGB/sync/blank signals share the overlay's 3 CE-enabled stages; CE stays the game's plain clk/6 enable.
wire credits_dismiss = |(joystick_0 | joystick_1) | |buttons | ps2_key[9] | OSD_STATUS;
wire c_ce, c_hs, c_vs, c_hb, c_vb;
wire [7:0] c_r, c_g, c_b;
ah_credits credits (
    .clk(clk_sys), .reset(power_reset), .ce_pix(ce_pix),
    .menu_trigger(status[120]), .dismiss(credits_dismiss),
    .direct_video(direct_video), .rot_menu(status[45:44]),
    .r_in(r), .g_in(g), .b_in(b), .hs_in(hs), .vs_in(vs), .hb_in(hblank), .vb_in(vblank),
    .ce_out(c_ce), .r_out(c_r), .g_out(c_g), .b_out(c_b),
    .hs_out(c_hs), .vs_out(c_vs), .hb_out(c_hb), .vb_out(c_vb), .active(credits_active)
);

wire signed [15:0] audio_f;
ah_audio audio_lp(.clk(clk_sys), .rst(game_rst), .bypass(status[43]), .in(game_audio), .out(audio_f));
assign AUDIO_L = audio_f;
assign AUDIO_R = audio_f;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'd0;

///////////////////////////////////////////////////////////////////////////////////// video
// CRT Adjust (analog/direct video geometry) sits at the raster boundary; Off = bypass.
wire signed [31:0] hsize_val = crt_menu_decode(int'(status[59:55]), CRT_HSIZE_MIN, CRT_HSIZE_MAX, 5);
wire [2:0] hsize_opt = hsize_val == 1 ? 3'd1 : hsize_val == -2 ? 3'd3 : hsize_val == -1 ? 3'd4 : 3'd0;
wire crt_en = status[54] && CRT_MENU_RANGES_VALID;
wire crt_ce, crt_active, crt_hs, crt_vs, crt_hb, crt_vb;
wire [7:0] crt_r, crt_g, crt_b;
ah_crt #(.HTOTAL(NATIVE_HTOTAL), .VTOTAL(NATIVE_VTOTAL), .PIX_CLKS(NATIVE_PIXEL_DIV)) crt (
    .clk(clk_sys), .reset(power_reset), .ce_in(c_ce), .enable(crt_en),
    .hsize_option(hsize_opt),
    .hpos_option(5'(crt_menu_decode(int'(status[66:60]), CRT_HPOS_MIN, CRT_HPOS_MAX, 7))),
    .vpos_option(5'(crt_menu_decode(int'(status[71:67]), CRT_VPOS_MIN, CRT_VPOS_MAX, 5))),
    .r_in(c_r), .g_in(c_g), .b_in(c_b), .hs_in(c_hs), .vs_in(c_vs), .hb_in(c_hb), .vb_in(c_vb),
    .ce_out(crt_ce), .active(crt_active), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
    .hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb), .read_period()
);
wire        o_ce  = crt_active ? crt_ce : c_ce;
wire [23:0] o_rgb = crt_active ? {crt_r, crt_g, crt_b} : {c_r, c_g, c_b};
wire        o_hs  = crt_active ? crt_hs : c_hs;
wire        o_vs  = crt_active ? crt_vs : c_vs;
wire        o_hb  = crt_active ? crt_hb : c_hb;
wire        o_vb  = crt_active ? crt_vb : c_vb;

wire VGA_DE_MIXER;
arcade_video #(.WIDTH(352), .DW(24), .GAMMA(1)) arcade_video (
    .clk_video(clk_sys), .ce_pix(o_ce), .RGB_in(o_rgb),
    .HBlank(o_hb), .VBlank(o_vb), .HSync(o_hs), .VSync(o_vs),
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE_MIXER),
    .VGA_SL(VGA_SL),
    .fx(direct_video ? 3'd0 : status[52:50]), .forced_scandoubler(forced_scandoubler), .gamma_bus
);

// Rotation (HDMI framebuffer path): Normal / 90 CW / 90 CCW / 180.  Direct video offers Normal/180 only.
// HDMI: Normal / 90 CW / 90 CCW / 180; direct video: Normal / 180.  180 is done in the game renderer (flip_180),
// so it works on every output (the screen_rotate framebuffer flip is bypassed by direct video); 90 uses screen_rotate.
wire [1:0] rot = direct_video ? {status[53], status[53]} : status[45:44];
wire no_rotate = (rot == 2'd0) || (rot == 2'd3) || direct_video;
wire rotate_ccw = (rot == 2'd2);
wire flip = 1'b0;
screen_rotate screen_rotate (
    .CLK_VIDEO, .CE_PIXEL, .VGA_R, .VGA_G, .VGA_B, .VGA_HS, .VGA_VS, .VGA_DE(VGA_DE_MIXER),
    .rotate_ccw, .no_rotate, .flip, .video_rotated,
    .FB_EN, .FB_FORMAT, .FB_WIDTH, .FB_HEIGHT, .FB_BASE, .FB_STRIDE, .FB_VBL, .FB_LL,
    .DDRAM_CLK, .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .DDRAM_RD
);

wire [1:0] ar = status[122:121];
wire rotated = ~no_rotate;
wire [11:0] arx = ar == 2'd0 ? (rotated ? 12'd3 : 12'd4) : (ar - 2'd1);
wire [11:0] ary = ar == 2'd0 ? (rotated ? 12'd4 : 12'd3) : 12'd0;
video_freak video_freak (
    .CLK_VIDEO, .CE_PIXEL, .VGA_VS, .HDMI_WIDTH, .HDMI_HEIGHT, .VGA_DE,
    .VIDEO_ARX, .VIDEO_ARY, .VGA_DE_IN(VGA_DE_MIXER),
    .ARX(arx), .ARY(ary), .CROP_SIZE(12'd0), .CROP_OFF(5'd0),
    .SCALE(status[47:46] == 2'd1 ? 3'd1 : status[47:46] == 2'd2 ? 3'd4 : 3'd0)
);

///////////////////////////////////////////////////////////////////////////////////// misc ports
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign {HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT} = 3'b000;
assign LED_USER = dl_busy;
assign {LED_DISK, LED_POWER, BUTTONS} = '0;
assign ADC_BUS = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
`ifdef MISTER_FB
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign {FB_PAL_CLK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = '0;
`endif
`endif
`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_A, SDRAM2_BA, SDRAM2_DQ, SDRAM2_CLK, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = 'z;
`endif
endmodule
