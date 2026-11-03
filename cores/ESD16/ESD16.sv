//============================================================================
//  ESD16 (SWAT Police, MAME swatpolc) for MiSTer.
//
//  Framework: MiSTer Template 5dda373 sys/ (unmodified). OSD/CRT layout follows HeavyUnit
//  (framework/OSD_MENU_PLAN.md). SDRAM: jtframe_sdram64 donor at 1x clk_sys (rtl/mem/esd16_sdram.sv).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu #(
 // Raster owned by rtl/esd16_video_line.sv: 98 MHz / 14 = 7 MHz pixel (PCB 14 MHz crystal / 2), 448 x 260,
 // 15.625 kHz / 60.096 Hz (clock_plan.json). Active x0..319 / y0..239.
 parameter integer NATIVE_HTOTAL=448, NATIVE_VTOTAL=260, NATIVE_PXDIV=14,
 // CRT Adjust centring tables in rtl/crt/esd16_crt.sv were derived for the former 64 MHz 512x260 raster.
 // They must be re-derived on sim/crt for 448x260 / 14-clock pixels; until then the CRT rows stay hidden.
 parameter bit CRT_CONTROLS_VALIDATED=0,
 parameter integer CRT_HSIZE_MIN=-2,CRT_HSIZE_MAX=2,CRT_HPOS_MIN=-16,CRT_HPOS_MAX=15,CRT_VPOS_MIN=-8,CRT_VPOS_MAX=8
)(
    `include "sys/emu_ports.vh"
);

///////////////////////////////////////////////////////////////////////////////
// Clocks / reset
///////////////////////////////////////////////////////////////////////////////
wire clk_sys, clk_sdram, clk_cap, pll_locked;
pll pll (.refclk(CLK_50M), .rst(1'b0), .outclk_0(clk_sys), .outclk_1(clk_sdram), .outclk_2(clk_cap), .locked(pll_locked));
// SDRAM_CLK forwarded through an IOE DDIO (inverted: high half drives 0) so it shares the DQ/command IOE timing.
altddio_out #(.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
    .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)) sdramclk_ddr (
    .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sdram), .dataout(SDRAM_CLK),
    .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
assign CLK_VIDEO = clk_sys;

wire power_reset = RESET || !pll_locked;
reg [2:0] reset_sync = 3'b111;
always @(posedge clk_sys or posedge power_reset)
    if (power_reset) reset_sync <= 3'b111;
    else             reset_sync <= {reset_sync[1:0], 1'b0};
wire cold_reset = reset_sync[2];

wire [127:0] status;
wire   [1:0] buttons;
wire         warm_reset = status[0] || buttons[1];
wire         forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;

`include "build_id.v"
`include "rtl/crt/esd16_crt_menu.vh"

localparam CONF_STR = {
    "ESD16;;",
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
    "-;",
    "R[0],Reset;",
    "J1,Fire,Dodge,Bomb,Start,Coin,Service Coin,Pause;",
    "v,1;V,v",`BUILD_DATE
};

///////////////////////////////////////////////////////////////////////////////
// HPS
///////////////////////////////////////////////////////////////////////////////
wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;
wire        ioctl_download, ioctl_upload, ioctl_wr;
wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
wire [26:0] ioctl_addr;
wire        ioctl_wait;
wire        nv_dirty;
wire        crt_available;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(), .gamma_bus(gamma_bus),
    .status(status), .buttons(buttons),
    // 0: Scandoubler Fx hidden in Direct Video; 1: framebuffer Rotation and Scaling hidden in Direct Video;
    // 2: 180-only Rotation shown only in Direct Video; 3: every CRT row hidden unless the CRT tables are validated;
    // 4: CRT sub-rows hidden until CRT Adjust is On
    .status_menumask({11'd0, !status[54], !(crt_available && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID),
                      !direct_video, direct_video, direct_video}),
    .video_rotated(video_rotated),
    .joystick_0(joystick_0), .joystick_1(joystick_1), .ps2_key(ps2_key),
    // SWAT consumes two digital sticks only. Optional outputs are opened;
    // unused framework inputs are tied to their idle values below.
    .joystick_2(), .joystick_3(), .joystick_4(), .joystick_5(),
    .joystick_l_analog_0(), .joystick_l_analog_1(), .joystick_l_analog_2(),
    .joystick_l_analog_3(), .joystick_l_analog_4(), .joystick_l_analog_5(),
    .joystick_r_analog_0(), .joystick_r_analog_1(), .joystick_r_analog_2(),
    .joystick_r_analog_3(), .joystick_r_analog_4(), .joystick_r_analog_5(),
    .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0), .joystick_2_rumble(16'd0),
    .joystick_3_rumble(16'd0), .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0),
    .paddle_0(), .paddle_1(), .paddle_2(), .paddle_3(), .paddle_4(), .paddle_5(),
    .spinner_0(), .spinner_1(), .spinner_2(), .spinner_3(), .spinner_4(), .spinner_5(),
    .ps2_kbd_clk_out(), .ps2_kbd_data_out(), .ps2_kbd_clk_in(1'b1), .ps2_kbd_data_in(1'b1),
    .ps2_kbd_led_status(3'd0), .ps2_kbd_led_use(3'd0),
    .ps2_mouse_clk_out(), .ps2_mouse_data_out(), .ps2_mouse_clk_in(1'b1), .ps2_mouse_data_in(1'b1),
    .ps2_mouse(), .ps2_mouse_ext(),
    .new_vmode(1'b0), .status_in(128'd0), .status_set(1'b0), .info_req(1'b0), .info(8'd0),
    .img_mounted(), .img_readonly(), .img_size(),
    .sd_lba('{default:32'd0}), .sd_blk_cnt('{default:6'd0}), .sd_rd('0), .sd_wr('0),
    .sd_ack(), .sd_buff_addr(), .sd_buff_dout(), .sd_buff_din('{default:16'd0}), .sd_buff_wr(),
    .ioctl_file_ext(), .sdram_sz(), .RTC(), .TIMESTAMP(), .uart_mode(), .uart_speed(),
    .forced_scandoubler(forced_scandoubler), .direct_video(direct_video),
    .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr), .ioctl_rd(),
    .ioctl_wait(ioctl_wait), .ioctl_din(ioctl_din),
    .ioctl_upload_req(nv_dirty), .ioctl_upload_index(8'd4)
);

///////////////////////////////////////////////////////////////////////////////
// Inputs. MAME swatpolc ports: P1_P2 bits {up,down,left,right,B1,B2,B3,unknown} per player (P2 at +8), idle 0xFFFF;
// SYSTEM {coin1,coin2,start1,start2,service1,-,test} bits 0..4,6, idle 0xFFFF (unused bit 7 is released high).
// MiSTer joystick bits: 0 right,1 left,2 down,3 up,4 Fire,5 Dodge,6 Bomb,7 Start,8 Coin,9 Service Coin,10 Pause.
///////////////////////////////////////////////////////////////////////////////
reg [31:0] key_p1, key_p2;
reg        key_svc1, key_test, key_toggle;
always @(posedge clk_sys) begin
    if (cold_reset) begin
        key_p1 <= 32'd0; key_p2 <= 32'd0; key_svc1 <= 1'b0; key_test <= 1'b0; key_toggle <= ps2_key[10];
    end else if (key_toggle != ps2_key[10]) begin
        key_toggle <= ps2_key[10];
        case (ps2_key[7:0])
            8'h75: key_p1[3] <= ps2_key[9];          // up
            8'h72: key_p1[2] <= ps2_key[9];          // down
            8'h6b: key_p1[1] <= ps2_key[9];          // left
            8'h74: key_p1[0] <= ps2_key[9];          // right
            8'h14: key_p1[4] <= ps2_key[9];          // Ctrl  : Fire
            8'h11: key_p1[5] <= ps2_key[9];          // Alt   : Dodge
            8'h29: key_p1[6] <= ps2_key[9];          // Space : Bomb
            8'h16: key_p1[7] <= ps2_key[9];          // 1     : Start 1
            8'h2e: key_p1[8] <= ps2_key[9];          // 5     : Coin 1
            8'h2d: key_p2[3] <= ps2_key[9];          // R up
            8'h2b: key_p2[2] <= ps2_key[9];          // F down
            8'h23: key_p2[1] <= ps2_key[9];          // D left
            8'h34: key_p2[0] <= ps2_key[9];          // G right
            8'h1c: key_p2[4] <= ps2_key[9];          // A
            8'h1b: key_p2[5] <= ps2_key[9];          // S     : Dodge
            8'h15: key_p2[6] <= ps2_key[9];          // Q     : Bomb
            8'h1e: key_p2[7] <= ps2_key[9];          // 2     : Start 2
            8'h36: key_p2[8] <= ps2_key[9];          // 6     : Coin 2
            8'h46: key_svc1  <= ps2_key[9];          // 9     : Service 1
            8'h06: key_test  <= ps2_key[9];          // F2    : Service / test
            default: ;
        endcase
    end
end
wire [31:0] joy1 = joystick_0 | key_p1;
wire [31:0] joy2 = joystick_1 | key_p2;
wire        service_coin_btn = joy1[9] | joy2[9] | key_svc1;
wire        pause_btn = joy1[10] | joy2[10];
wire [15:0] in_p1p2_n = ~{1'b0, joy2[6], joy2[5], joy2[4], joy2[0], joy2[1], joy2[2], joy2[3],
                          1'b0, joy1[6], joy1[5], joy1[4], joy1[0], joy1[1], joy1[2], joy1[3]} | 16'h8080;
wire [15:0] in_system_n = ~{9'd0, key_test, 1'b0, service_coin_btn, joy2[7], joy1[7], joy2[8], joy1[8]}; // idle SYSTEM=0xFFFF

///////////////////////////////////////////////////////////////////////////////
// Game
///////////////////////////////////////////////////////////////////////////////
wire        sd_init, dl_busy;
reg         rom_loaded, prev_dl;
always @(posedge clk_sys) begin
    prev_dl <= dl_busy;
    if (cold_reset) rom_loaded <= 1'b0;
    else if (dl_busy) rom_loaded <= 1'b0;
    else if (prev_dl) rom_loaded <= 1'b1;      // download (and its flush) just finished
end

wire game_rst = cold_reset || warm_reset || sd_init || dl_busy || !rom_loaded;
reg  pause_toggle, pause_btn_d;
always @(posedge clk_sys) begin
    if (game_rst) begin
        pause_toggle <= 1'b0;
        pause_btn_d  <= pause_btn;
    end else begin
        pause_btn_d <= pause_btn;
        if (pause_btn && !pause_btn_d) pause_toggle <= ~pause_toggle;
    end
end
wire pause = pause_toggle || (OSD_STATUS && status[41]);

wire cen_phi1, cen_phi2, cen_z80, cen_ym, cen_oki, nmi_tick, cpu_wait, cpu_recovering;
esd16_cen cen (
    .clk(clk_sys), .rst(game_rst), .pause(pause), .cpu_wait(cpu_wait),
    .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80), .cen_ym(cen_ym), .cen_oki(cen_oki),
    .nmi_tick(nmi_tick), .cpu_recovering(cpu_recovering));

wire        cpu_rom_en, cpu_rom_ok, zrom_ok, orom_ok;
wire        bgrom_req, bgrom_ready, bgrom_valid, sprom_req, sprom_ready, sprom_valid, sprom2_req, sprom2_ready, sprom2_valid;
wire [18:1] cpu_rom_addr;
wire [15:0] cpu_rom_data;
wire [17:0] zrom_addr, orom_addr;
wire  [7:0] zrom_data, orom_data;
wire [20:0] bgrom_addr, sprom_addr, sprom2_addr;
wire [31:0] bgrom_data, sprom_data, sprom2_data;
wire  [7:0] g_r, g_g, g_b;
wire        g_ce, g_hs, g_vs, g_hb, g_vb, line_overrun;
wire signed [15:0] snd;

// NVRAM (93C46 image, 128 bytes, MRA <nvram index="4">): word index = ioctl_addr[6:1]; raw words are little endian
// Main_MiSTer WIDE carries file byte 0 in bits [7:0], matching the pinned MAME EEPROM format.
wire        nv_dl_wr  = ioctl_download && ioctl_wr && (ioctl_index[7:0] == 8'd4);
wire [15:0] nv_dout, nv_din = ioctl_dout;
wire        nv_changed;
assign ioctl_din = nv_dout;
reg  ioctl_upload_d;
always @(posedge clk_sys) ioctl_upload_d <= ioctl_upload;
reg  nv_dirty_r;
always @(posedge clk_sys) begin
    if (cold_reset || (ioctl_upload && !ioctl_upload_d)) nv_dirty_r <= 1'b0;
    else if (nv_changed) nv_dirty_r <= 1'b1;
end
assign nv_dirty = nv_dirty_r;

esd16_top game (
    .clk(clk_sys), .rst(game_rst), .vrst(cold_reset),
    .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80), .cen_ym(cen_ym), .cen_oki(cen_oki),
    .nmi_tick(nmi_tick), .cpu_wait(cpu_wait),
    .in_p1p2_n(in_p1p2_n), .in_system_n(in_system_n),
    .cpu_rom_en(cpu_rom_en), .cpu_rom_addr(cpu_rom_addr), .cpu_rom_data(cpu_rom_data), .cpu_rom_ok(cpu_rom_ok),
    .zrom_addr(zrom_addr), .zrom_data(zrom_data), .zrom_ok(zrom_ok),
    .orom_addr(orom_addr), .orom_data(orom_data), .orom_ok(orom_ok),
    .bgrom_req(bgrom_req), .bgrom_addr(bgrom_addr), .bgrom_ready(bgrom_ready), .bgrom_valid(bgrom_valid), .bgrom_data(bgrom_data),
    .sprom_req(sprom_req), .sprom_addr(sprom_addr), .sprom_ready(sprom_ready), .sprom_valid(sprom_valid), .sprom_data(sprom_data),
    .sprom2_req(sprom2_req), .sprom2_addr(sprom2_addr), .sprom2_ready(sprom2_ready), .sprom2_valid(sprom2_valid), .sprom2_data(sprom2_data),
    .vid_r(g_r), .vid_g(g_g), .vid_b(g_b), .vid_ce(g_ce), .vid_hs(g_hs), .vid_vs(g_vs), .vid_hb(g_hb), .vid_vb(g_vb),
    .vid_line_overrun(line_overrun), .user_flip(user_flip),
    .nv_addr(ioctl_addr[6:1]), .nv_wr(nv_dl_wr), .nv_din(nv_din), .nv_dout(nv_dout), .nv_changed(nv_changed),
    .snd(snd));

esd16_sdram sdram (
    .clk(clk_sys), .clk_cap(clk_cap), .rst(cold_reset), .init(sd_init),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait), .dl_busy(dl_busy),
    .rfsh(g_hb),
    .cpu_en(cpu_rom_en), .cpu_addr(cpu_rom_addr), .cpu_data(cpu_rom_data), .cpu_ok(cpu_rom_ok),
    .zrom_addr(zrom_addr), .zrom_data(zrom_data), .zrom_ok(zrom_ok),
    .orom_addr(orom_addr), .orom_data(orom_data), .orom_ok(orom_ok),
    .bgrom_req(bgrom_req), .bgrom_addr(bgrom_addr), .bgrom_ready(bgrom_ready), .bgrom_valid(bgrom_valid), .bgrom_data(bgrom_data),
    .sprom_req(sprom_req), .sprom_addr(sprom_addr), .sprom_ready(sprom_ready), .sprom_valid(sprom_valid), .sprom_data(sprom_data),
    .sprom2_req(sprom2_req), .sprom2_addr(sprom2_addr), .sprom2_ready(sprom2_ready), .sprom2_valid(sprom2_valid), .sprom2_data(sprom2_data),
    .sdram_dq(SDRAM_DQ), .sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
    .sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS),
    .sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE));

///////////////////////////////////////////////////////////////////////////////
// Video: game raster -> CRT Adjust (optional) -> arcade_video (scandoubler/gamma) -> video_freak -> screen_rotate
///////////////////////////////////////////////////////////////////////////////
// Rotation (HeavyUnit layout): 90 CW / 90 CCW use the MiSTer DDR framebuffer (not available in Direct Video);
// 180 flips the game renderer itself, so it also works on CRT / Direct Video.
wire [1:0] rotation    = status[45:44];
wire       user_flip   = direct_video ? status[53] : (rotation == 2'd3);
wire       no_rotate   = direct_video || !(rotation == 2'd1 || rotation == 2'd2);
wire       rotate_ccw  = rotation == 2'd2;
wire       video_rotated;

// CRT Adjust glue (HeavyUnit donor), tables derived for this raster (see parameter note).
assign crt_available = 1'b1;
wire crt_en = status[54] && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID;
wire signed [4:0] crt_hsize     = $signed(5'(crt_menu_decode(int'(status[59:55]), CRT_HSIZE_MIN, CRT_HSIZE_MAX, 5)));
wire signed [6:0] crt_hposition = $signed(7'(crt_menu_decode(int'(status[66:60]), CRT_HPOS_MIN, CRT_HPOS_MAX, 7)));
wire signed [4:0] crt_vposition = $signed(5'(crt_menu_decode(int'(status[71:67]), CRT_VPOS_MIN, CRT_VPOS_MAX, 5)));
wire [2:0] crt_hsize_option = crt_hsize == 5'sd1 ? 3'd1 : crt_hsize == 5'sd2 ? 3'd2 :
                              crt_hsize == -5'sd2 ? 3'd3 : crt_hsize == -5'sd1 ? 3'd4 : 3'd0;
wire        crt_ce_o, crt_active;
wire  [7:0] crt_r, crt_g, crt_b;
wire        crt_hs, crt_vs, crt_hb, crt_vb;
esd16_crt #(.HTOTAL(NATIVE_HTOTAL), .VTOTAL(NATIVE_VTOTAL), .PXDIV(NATIVE_PXDIV)) crt (
    .clk(clk_sys), .reset(cold_reset), .ce_in(g_ce), .enable(crt_en),
    .hsize_option(crt_hsize_option), .hpos_option(crt_hposition[4:0]), .vpos_option(crt_vposition[4:0]),
    .r_in(g_r), .g_in(g_g), .b_in(g_b), .hs_in(g_hs), .vs_in(g_vs), .hb_in(g_hb), .vb_in(g_vb),
    .ce_out(crt_ce_o), .active(crt_active), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
    .hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb), .read_period());
wire        v_ce = crt_active ? crt_ce_o : g_ce;
wire [23:0] v_rgb = crt_active ? {crt_r, crt_g, crt_b} : {g_r, g_g, g_b};
wire        v_hs = crt_active ? crt_hs : g_hs;
wire        v_vs = crt_active ? crt_vs : g_vs;
wire        v_hb = crt_active ? crt_hb : g_hb;
wire        v_vb = crt_active ? crt_vb : g_vb;

wire        av_ce, av_hs, av_vs, av_de;
wire  [7:0] av_r, av_g, av_b;
arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video (
    .clk_video(clk_sys), .ce_pix(v_ce), .RGB_in(v_rgb),
    .HBlank(v_hb), .VBlank(v_vb), .HSync(v_hs), .VSync(v_vs),
    .CLK_VIDEO(), .CE_PIXEL(av_ce), .VGA_R(av_r), .VGA_G(av_g), .VGA_B(av_b),
    .VGA_HS(av_hs), .VGA_VS(av_vs), .VGA_DE(av_de), .VGA_SL(VGA_SL),
    .fx(direct_video ? 3'd0 : status[52:50]), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus));

wire [1:0]  ar    = status[122:121];
wire [11:0] arx   = (ar == 2'd0) ? (no_rotate ? 12'd4 : 12'd3) : {10'd0, (ar - 2'd1)};
wire [11:0] ary   = (ar == 2'd0) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0;
wire [2:0]  scale = (status[47:46] == 2'd1) ? 3'd1 : (status[47:46] == 2'd2) ? 3'd4 : 3'd0;
wire        fk_de;
video_freak video_freak (
    .CLK_VIDEO(clk_sys), .CE_PIXEL(av_ce), .VGA_VS(av_vs), .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(fk_de), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(av_de), .ARX(arx), .ARY(ary), .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE(scale));

assign CE_PIXEL = av_ce;
assign VGA_R = av_r;  assign VGA_G = av_g;  assign VGA_B = av_b;
assign VGA_HS = av_hs; assign VGA_VS = av_vs; assign VGA_DE = fk_de;
assign {VGA_F1, VGA_SCALER, VGA_DISABLE, HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT} = 6'd0;

///////////////////////////////////////////////////////////////////////////////
// Audio (mono, signed): YM3812 + OKI mixed in esd16_sound at MAME levels
///////////////////////////////////////////////////////////////////////////////
assign AUDIO_L   = snd;
assign AUDIO_R   = snd;
assign AUDIO_S   = 1'b1;
assign AUDIO_MIX = 2'd0;

///////////////////////////////////////////////////////////////////////////////
// Unused platform pins (Template defaults)
///////////////////////////////////////////////////////////////////////////////
assign LED_USER  = dl_busy | sd_init | line_overrun;
assign {LED_DISK, LED_POWER, BUTTONS} = 6'd0;
assign ADC_BUS   = 4'bzzzz;
assign USER_OUT  = 7'h7F;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'd0;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;

///////////////////////////////////////////////////////////////////////////////
// 90-degree rotation framebuffer (stock sys/arcade_video.v screen_rotate). Its one-cycle DDR writes go through
// esd16_rotate_ddr_queue, which holds each write until DDRAM_BUSY is low (the stock writer ignores BUSY).
///////////////////////////////////////////////////////////////////////////////
wire        sr_we;
wire [28:0] sr_addr;
wire [63:0] sr_din;
wire  [7:0] sr_be;
screen_rotate screen_rotate (
    .CLK_VIDEO(clk_sys), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
    .rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(1'b0), .video_rotated(video_rotated),
    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din), .DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(DDRAM_RD));
assign FB_FORCE_BLANK = 1'b0;
esd16_rotate_ddr_queue rotate_ddr_queue (
    .clk(clk_sys), .reset(cold_reset),
    .in_we(sr_we), .in_addr(sr_addr), .in_din(sr_din[31:0]), .in_be(sr_be),
    .busy(DDRAM_BUSY), .out_we(DDRAM_WE), .out_addr(DDRAM_ADDR), .out_din(DDRAM_DIN), .out_be(DDRAM_BE),
    .overflow());

endmodule
