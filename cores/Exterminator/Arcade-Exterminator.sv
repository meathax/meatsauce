//============================================================================
//  Exterminator (Premier Technology / Gottlieb, 1989; MAME set "exterm") -- MiSTer emu wrapper
//  Lane 4 (framework).  Game core: rtl/exterm_core.sv (orchestrator, lanes 1-3).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  Structure follows donors/NARC (TMS34010 + single SDRAM, hardware-proven wrapper) for clocks,
//  reset and loading, and donors/simple156 (OSMAN, the CRT reference core) for the Video & CRT
//  options.  See docs/lane4_framework.md.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

`include "build_id.v"
`ifndef BUILD_DATE
`define BUILD_DATE "EXTERM"
`endif

///////////////////////////////////////////////////////////////////////
// Raster (hwspec.md): single source of truth for CRT Adjust sizing.
localparam H_TOTAL = 318;
localparam V_TOTAL = 264;
// Resource switches (LAB budget, docs/lane4_framework.md): HQ2x (~650 ALM) is compiled out unless the
// project defines EXTERM_USE_HQ2X; the OSD gamma curve (~340 ALM) unless EXTERM_USE_GAMMA.
`ifdef EXTERM_USE_HQ2X
localparam USE_HQ2X = 1;
`define FX_LIST "None,HQ2x,CRT25%,CRT50%,CRT75%"
`else
localparam USE_HQ2X = 0;
`define FX_LIST "None,CRT25%,CRT50%,CRT75%"
`endif
`ifdef EXTERM_USE_GAMMA
localparam USE_GAMMA = 1;
`else
localparam USE_GAMMA = 0;
`endif

///////////////////////////////////////////////////////////////////////
// OSD.   Status bit map:
//  [0]   reset            [2:1] reserved (former pause controls)
//  [3]   autosave (0=On)  [6]  service switch    [7]  sound filter (MAME / PCB)
//  [8]   aim reverse      [11:9] aim sensitivity [16:15] rotate-button speed
//  [14:12] scandoubler FX [19:17] scale          [20] crop 224
//  [22:21] mouse aims     [23] analog stick aims
//  [32] CRT adjust  [37:33] H-size  [42:38] H-pos  [47:43] V-pos   (identical to OSMAN.sv)
//  [49:48] rotation       [122:121] aspect ratio
localparam CONF_STR = {
	"Exterminator;;",
	"P1,Video Settings;",
	"H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0P1O[49:48],Rotation,None,90 CW,90 CCW,180 Flip;",
	"H0P1O[19:17],Scaling,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
	"H0P1O[20],Crop to 224 lines,Off,On;",
	{"P1O[14:12],Scandoubler FX,", `FX_LIST, ";"},
	"P1-;",
	"P1O[32],CRT Adjust,Off,On;",
	"H2P1O[37:33],CRT H-Size,0,+1,+2,+3,+4,+5,+6,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[42:38],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2P1O[47:43],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P2,Game Settings;",
	"P2O[3],Autosave Scores,On,Off;",
	"P2O[6],Service switch,Off,On;",
	"P2O[7],Sound filter,MAME,PCB;",
	"P2-;",
	"P2O[8],Aim direction,Normal,Reversed;",
	"P2O[11:9],Aim sensitivity,x1,x0.5,x0.25,x2,x3,x4,x1.5,x0.75;",
	"P2O[16:15],Rotate button speed,5,8,3,2;",
	"P2O[22:21],Mouse aims,Player 1,Player 2,Off;",
	"P2O[23],Analog stick X aims,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// J1 must stay AFTER every menu item (a leading J1 shifts the main-page selection).
	// Function names are the game's own (Test Menu > Player Switch Test): JOYSTICK FIRE, POUND, ROTATE.
	"J1,Fire,Pound,Rotate Left,Rotate Right,Start,Coin,Service;",
	"jn,A,B,L,R,Start,Select,X,Y;",
	"v,1;",
	"V,v",`BUILD_DATE
};

///////////////////////////////////////////////////////////////////////
// Clocks:  clk_ram 80 MHz (SDRAM), clk_sys 20 MHz (game, CLK_VIDEO), SDRAM_CLK 80 MHz +180 deg
wire clk_sys, clk_ram, pll_locked;
pll pll
(
	.refclk_clk(CLK_50M),
	.reset_reset(1'b0),
	.outclk0_clk(clk_ram),
	.outclk1_clk(clk_sys),
	.outclk2_clk(SDRAM_CLK),
	.locked_export(pll_locked)
);

///////////////////////////////////////////////////////////////////////
// HPS
wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler, direct_video;
wire  [21:0] gamma_bus;
wire         ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout, ioctl_din;
wire         ioctl_upload_req;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire   [7:0] paddle_0, paddle_1;
wire   [8:0] spinner_0, spinner_1;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire         video_rotated;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	// H0 hides in Direct Video, H2 hides the CRT amounts until CRT Adjust is On
	.status_menumask({13'd0, ~status[32], 1'b0, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.video_rotated(video_rotated),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),            // NVRAM image, MRA <nvram index="4">
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.paddle_0(paddle_0),
	.paddle_1(paddle_1),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
);

///////////////////////////////////////////////////////////////////////
// Reset: async assert (PLL, HPS reset, OSD reset, user button), 2-flop synchronous release.
// The game core is additionally held in reset for EVERY download (ROM index 0, DIP index 254,
// NVRAM index 4) so it never executes against a half-loaded image or half-restored NVRAM.
wire rst_sys;
exterm_reset_sync u_rst (.clk(clk_sys), .arst(RESET | status[0] | buttons[1] | ~pll_locked), .rst(rst_sys));
wire core_rst = rst_sys | ioctl_download;

// ROM stream: MRA index 0 = maincpu 2 MB, audiocpu 32 KB, speechcpu 32 KB (0x210000 bytes)
wire rom_dl      = ioctl_download && (ioctl_index == 16'd0);
wire core_ld_busy;
assign ioctl_wait = rom_dl & core_ld_busy;

// DIP switches (MRA <switches>, ioctl index 254).  MAME default DSW = 0xFF.
reg [7:0] dsw = 8'hFF;
always @(posedge clk_sys)
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && (ioctl_addr[26:0] == 27'd0))
		dsw <= ioctl_dout;

///////////////////////////////////////////////////////////////////////
// Inputs
wire [15:0] in_p1, in_p2;
wire        rot_inc1, rot_dec1, rot_inc2, rot_dec2;

exterm_inputs u_inputs
(
	.clk(clk_sys), .rst(rst_sys),
	.joy0(joystick_0), .joy1(joystick_1),
	.ps2_key(ps2_key),
	.svc_opt(status[6]),
	.in_p1(in_p1), .in_p2(in_p2),
	.rot_inc_p1(rot_inc1), .rot_dec_p1(rot_dec1),
	.rot_inc_p2(rot_inc2), .rot_dec_p2(rot_dec2)
);

// ~60 Hz tick for the button / analog-stick aim rates (20 MHz / 333333)
reg [18:0] tcnt = 19'd0;
wire       tick60 = (tcnt == 19'd333332);
always @(posedge clk_sys) tcnt <= tick60 ? 19'd0 : tcnt + 19'd1;

// mouse packet -> X delta event for the selected player
reg  old_mtog;
always @(posedge clk_sys) old_mtog <= ps2_mouse[24];
wire        mouse_ev  = (ps2_mouse[24] != old_mtog);
wire signed [8:0] mouse_dx = {ps2_mouse[4], ps2_mouse[15:8]};

wire [7:0] dial_p1, dial_p2;
exterm_aim u_aim1
(
	.clk(clk_sys), .rst(rst_sys), .tick(tick60),
	.rev(status[8]), .sens(status[11:9]), .key_speed(status[16:15]),
	.key_inc(rot_inc1), .key_dec(rot_dec1),
	.spinner(spinner_0), .paddle(paddle_0),
	.mouse_ev(mouse_ev && (status[22:21] == 2'd0)), .mouse_dx(mouse_dx),
	.analog_en(status[23]), .analog_x(joystick_l_analog_0[7:0]),
	.dial(dial_p1)
);
exterm_aim u_aim2
(
	.clk(clk_sys), .rst(rst_sys), .tick(tick60),
	.rev(status[8]), .sens(status[11:9]), .key_speed(status[16:15]),
	.key_inc(rot_inc2), .key_dec(rot_dec2),
	.spinner(spinner_1), .paddle(paddle_1),
	.mouse_ev(mouse_ev && (status[22:21] == 2'd1)), .mouse_dx(mouse_dx),
	.analog_en(status[23]), .analog_x(joystick_l_analog_1[7:0]),
	.dial(dial_p2)
);

///////////////////////////////////////////////////////////////////////
// NVRAM (4 KB, ioctl index 4) and hi-score autosave
wire        nv_clk_en, nv_we;
wire [11:0] nv_addr;
wire  [7:0] nv_din, nv_dout;

exterm_nvram u_nvram
(
	.clk(clk_sys), .rst(core_rst), .autosave(~status[3]), .OSD_STATUS(OSD_STATUS),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_index(ioctl_index), .ioctl_dout(ioctl_dout),
	.ioctl_upload(ioctl_upload), .ioctl_din(ioctl_din), .ioctl_upload_req(ioctl_upload_req),
	.nv_clk_en(nv_clk_en), .nv_we(nv_we), .nv_addr(nv_addr), .nv_din(nv_din), .nv_dout(nv_dout)
);

///////////////////////////////////////////////////////////////////////
// Game core
wire  [4:0] core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb, core_ce;
wire signed [15:0] core_audio;
wire  [1:0] coin_counter;       // not used by the MiSTer wrapper

exterm_core core
(
	.clk(clk_sys), .clk_ram(clk_ram), .rst(core_rst), .rst_mem(~pll_locked),   /* SDRAM controller: PLL lock ONLY, like the hardware-proven NARC core. MiSTer Main asserts RESET/status[0] during an MRA ROM load; holding the controller in init then freezes 'Sending ROM #0' */
	.in_p1(in_p1), .in_p2(in_p2), .dsw(dsw), .dial_p1(dial_p1), .dial_p2(dial_p2),
	.ld_en(rom_dl), .ld_wr(rom_dl & ioctl_wr), .ld_addr(ioctl_addr[24:0]), .ld_data(ioctl_dout),
	.ld_busy(core_ld_busy),
	.nv_clk_en(nv_clk_en), .nv_we(nv_we), .nv_addr(nv_addr), .nv_din(nv_din), .nv_dout(nv_dout),
	.snd_filter({1'b0, status[7]}),
	.r(core_r), .g(core_g), .b(core_b),
	.hs(core_hs), .vs(core_vs), .hblank(core_hb), .vblank(core_vb), .ce_pix(core_ce),
	.audio(core_audio),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_BA(SDRAM_BA), .SDRAM_CKE(SDRAM_CKE),
	.coin_counter(coin_counter)
);

///////////////////////////////////////////////////////////////////////
// Audio: 16-bit signed mono -> both channels (clk_sys -> CLK_AUDIO mailbox)
wire signed [15:0] audio_cdc;
wire signed [15:0] audio_dcb;
exterm_audio_dc u_adc (.clk(clk_sys), .rst(core_rst), .din(core_audio), .dout(audio_dcb));   // DC-blocking high-pass, ~7.5 Hz
exterm_audio_cdc u_acdc (.clk_sys(clk_sys), .clk_audio(CLK_AUDIO), .rst(core_rst), .audio_in(audio_dcb), .audio_out(audio_cdc));
assign AUDIO_L   = audio_cdc;
assign AUDIO_R   = audio_cdc;
assign AUDIO_S   = 1'b1;
assign AUDIO_MIX = 2'd0;

///////////////////////////////////////////////////////////////////////
// Video
// 1. framework boot raster while the core is in reset (keeps sync alive during loading)
wire        boot_ce, boot_hs, boot_vs, boot_hb, boot_vb;
wire  [7:0] boot_r, boot_g, boot_b;
exterm_boot_video u_boot (.clk(clk_sys), .loading(ioctl_download), .ce(boot_ce),
	.hs(boot_hs), .vs(boot_vs), .hb(boot_hb), .vb(boot_vb), .r(boot_r), .g(boot_g), .b(boot_b));

wire        vid_ce = core_rst ? boot_ce : core_ce;
wire        vid_hs = core_rst ? boot_hs : core_hs;
wire        vid_vs = core_rst ? boot_vs : core_vs;
wire        vid_hb = core_rst ? boot_hb : core_hb;
wire        vid_vb = core_rst ? boot_vb : core_vb;
wire  [7:0] vid_r  = core_rst ? boot_r  : {core_r, core_r[4:2]};
wire  [7:0] vid_g  = core_rst ? boot_g  : {core_g, core_g[4:2]};
wire  [7:0] vid_b  = core_rst ? boot_b  : {core_b, core_b[4:2]};

// 2. CRT Adjust (core-side; Off = byte-identical passthrough)
wire  [7:0] adj_r, adj_g, adj_b;
wire        adj_hs, adj_vs, adj_hb, adj_vb, adj_ce;
exterm_crt #(.H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL)) u_crt
(
	.clk(clk_sys), .ce_pix(vid_ce),
	.crt_on(status[32]),
	.hsize_code(status[37:33]),
	.hpos($signed(status[42:38])),
	.vpos($signed(status[47:43])),
	.r_in(vid_r), .g_in(vid_g), .b_in(vid_b),
	.hs_in(vid_hs), .vs_in(vid_vs), .hb_in(vid_hb), .vb_in(vid_vb),
	.r_out(adj_r), .g_out(adj_g), .b_out(adj_b),
	.hs_out(adj_hs), .vs_out(adj_vs), .hb_out(adj_hb), .vb_out(adj_vb),
	.ce_out(adj_ce)
);

// 3. arcade_video: scandoubler / HQ2x / scanlines / gamma, CLK_VIDEO = clk_sys, CE_PIXEL = pixel enable
wire mixed_de;
// OSD FX code -> arcade_video fx (0 none, 1 HQ2x, 2..4 CRT 25/50/75); without HQ2x the list starts at CRT25 = 2
wire [2:0] fx_sel = USE_HQ2X ? status[14:12] : (status[14:12] == 3'd0 ? 3'd0 : (status[14:12] + 3'd1));
arcade_video #(.WIDTH(256), .DW(24), .GAMMA(USE_GAMMA), .HQ2X(USE_HQ2X)) arcade_video
(
	.clk_video(clk_sys), .ce_pix(adj_ce),
	.RGB_in({adj_r, adj_g, adj_b}),
	.HBlank(adj_hb), .VBlank(adj_vb), .HSync(adj_hs), .VSync(adj_vs),
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(mixed_de), .VGA_SL(VGA_SL),
	.fx(fx_sel), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
);

// 4. aspect / crop / integer scaling.  Rotation is off in Direct Video (analog path stays native).
wire [1:0] aspect    = direct_video ? 2'd0 : status[122:121];
wire [1:0] rot_sel   = direct_video ? 2'd0 : status[49:48];       // 0 none, 1 CW, 2 CCW, 3 180 flip
wire       rot90     = (rot_sel == 2'd1) || (rot_sel == 2'd2);
wire [12:0] video_arx, video_ary;

// ONE shared scaler: exterm_freak is video_freak with a single video_scale_int whose operands are
// transposed for 90-degree rotation (what the former second instance did from FB_WIDTH/FB_HEIGHT).
// ARY = 0 denotes a framework custom-aspect index and is preserved.
exterm_freak u_video_freak
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE_IN(mixed_de), .VGA_DE(VGA_DE),
	.VIDEO_ARX(video_arx), .VIDEO_ARY(video_ary),
	.ARX(!aspect ? 12'd4 : {10'd0, aspect} - 12'd1),
	.ARY(!aspect ? 12'd3 : 12'd0),
	.CROP_SIZE((!direct_video && status[20]) ? 12'd224 : 12'd0),
	.CROP_OFF(5'd0),
	.SCALE(direct_video ? 3'd0 : status[19:17]),
	.rot90(rot90)
);
assign VIDEO_ARX = video_arx;
assign VIDEO_ARY = video_ary;

// 5. rotation / flip through the DDR framebuffer (HDMI path only; hardened screen_rotate)
wire rot_ovf;
exterm_screen_rotate u_rotate
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rot_sel == 2'd2),
	.no_rotate(~rot90),
	.flip(rot_sel == 2'd3),
	.video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD),
	.fifo_ovf(rot_ovf)
);
assign FB_FORCE_BLANK = 1'b0;

///////////////////////////////////////////////////////////////////////
// Static outputs
assign VGA_F1         = 1'b0;
assign VGA_SCALER     = 1'b0;      // keep native analog output available (video-output rule 11)
assign VGA_DISABLE    = 1'b0;
assign HDMI_FREEZE    = 1'b0;
assign HDMI_BLACKOUT  = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign LED_USER  = ioctl_download | rot_ovf;
assign LED_DISK  = 2'd0;
assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'd0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

endmodule
