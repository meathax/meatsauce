`include "build_id.v"
localparam CONF_STR={
    "SPY;;",
    "P1,Video Settings;",
    "P2,Game Settings;",
    "-;",
    `include "rtl/framework/spy_dip_menu.vh"
    "R[120],Credits;",
    "-;",
    "R[0],Reset;",
    "H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "H0P1O[49:48],Rotation,Native,90 CW,90 CCW,180;",
    "H0P1O[10:8],Scaling,Normal,V-Integer,HV-Integer,HV-Integer-;",
    "H4P1O[56],HV Integer rounding,Down,Up;",
    "H0P1O[14:12],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "P1-;",
    "P1O[32],CRT Adjust,Off,On;",
    "H3P1O[57],Direct video180,Off,On;",
    "H2P1O[37:33],CRT H-Size,0,+1,+2,+3,+4,+5,+6,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[42:38],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[47:43],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "D1P2O[11],Autosave Hi-Score,On,Off;",
    "P2O[1],Pause When OSD Open,On,Off;",
    "J1,Punch/Kick,Kick/Shoot,Start,Coin,Service,Pause;",
    "v,1;V,v",`BUILD_DATE};
wire clk_sys,clk_sdram,pll_locked;
spy_pll u_clock(.refclk(CLK_50M),.reset(1'b0),.clk(clk_sys),.clk_sdram(clk_sdram),.locked(pll_locked));
wire global_reset_request=RESET||!pll_locked;
wire global_reset;
spy_reset_release u_global_reset(.clk(clk_sys),.async_reset(global_reset_request),.reset(global_reset));
// Forward the related PHY-only quarter-phase output. Actual counter phase and
// all-corner pin setup/hold must be verified in the sealed fitted snapshot.
altddio_out #(.width(1),.intended_device_family("Cyclone V"),.power_up_high("OFF"))
u_sdram_clock(.datain_h(1'b1),.datain_l(1'b0),.outclock(clk_sdram),.dataout(SDRAM_CLK),
    .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
wire [127:0] status;wire [1:0] buttons;wire [31:0] joystick_0,joystick_1;
wire [10:0] ps2_key;wire forced_scandoubler,direct_video;
wire [21:0] gamma_bus;wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_wait;
wire [7:0] ioctl_index,ioctl_dout,ioctl_din;wire [26:0] ioctl_addr;wire [15:0] ioctl_index_full;
assign ioctl_index=ioctl_index_full[7:0];
wire hs_configured,hs_upload_req;
wire [15:0] menu_mask;
wire [127:0] input_status;
wire [1:0] rotation;
wire [2:0] image_scale;
spy_video_options u_video_options(.status(status),.direct_video(direct_video),.hs_configured(hs_configured),
    .menu_mask(menu_mask),.input_status(input_status),.rotation(rotation),.image_scale(image_scale));
hps_io #(.CONF_STR(CONF_STR)) u_hps(.clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),
    .status(status),.buttons(buttons),.joystick_0(joystick_0),.joystick_1(joystick_1),
    .ps2_key(ps2_key),.forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
    .gamma_bus(gamma_bus),.status_menumask(menu_mask),
    .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),.ioctl_upload_index(8'd4),
    .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_index(ioctl_index_full),.ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),.ioctl_wait(ioctl_wait));
wire [7:0] system_in,p1_in,p2_in,dip1,dip2;wire user_paused,hs_pause;
spy_inputs u_inputs(.clk(clk_sys),.reset(global_reset),.joystick_0(joystick_0),.joystick_1(joystick_1),
    .ps2_key(ps2_key),.status(input_status),.osd_open(OSD_STATUS),.system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.dip1(dip1),.dip2(dip2),.paused(user_paused));
wire paused=user_paused||hs_pause;
wire image_ready,load_error;
wire game_reset_request=global_reset||status[0]||buttons[1]||!image_ready||(ioctl_download&&ioctl_index==0);
wire game_reset;
spy_reset_release u_game_reset(.clk(clk_sys),.async_reset(game_reset_request),.reset(game_reset));
wire startup_ce,startup_hs,startup_vs,startup_hb,startup_vb;
spy_startup_video u_startup(.clk(clk_sys),.reset(global_reset),.ce(startup_ce),.hs(startup_hs),.vs(startup_vs),.hblank(startup_hb),.vblank(startup_vb));
wire [17:0] main_addr,o_addr;wire main_cs,f_cs,a_cs,b_cs,o_cs;
wire [16:0] f_addr,a_addr,b_addr;wire [7:0] main_data;
wire [31:0] f_data,a_data,b_data,o_data;wire main_ok,f_ok,a_ok,b_ok,o_ok;
wire [7:0] red,green,blue,sound_latch;wire ce_pix,hs,vs,lhbl,lvbl,sound_irq,game_watchdog;
wire [12:0] state_addr;wire [7:0] state_din,state_dout;wire state_req,state_we,state_grant;
spy_game u_game(.clk(clk_sys),.reset(game_reset),.pause(paused),
    .system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.dip1(dip1),.dip2(dip2),
    .main_addr(main_addr),.main_cs(main_cs),.main_data(main_data),.main_ok(main_ok),
    .f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.o_addr(o_addr),.f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),.o_cs(o_cs),
    .f_data(f_data),.a_data(a_data),.b_data(b_data),.o_data(o_data),.a_ok(a_ok),.o_ok(o_ok),
    .red(red),.green(green),.blue(blue),.ce_pix(ce_pix),.hs(hs),.vs(vs),.lhbl(lhbl),.lvbl(lvbl),
    .hdump(),.vdump(),.debug_addr(),.debug_control(),.debug_registers(),.sound_latch(sound_latch),.sound_irq(sound_irq),.watchdog_expired(game_watchdog)
    `ifdef SPY_GAME_STATE
    ,.state_req(state_req),.state_we(state_we),.state_addr(state_addr),.state_din(state_din),.state_grant(state_grant),.state_dout(state_dout)
    `endif
);
wire [14:0] sound_addr;wire sound_cs,sound_ok;wire [7:0] sound_data;
wire [18:0] pcm0_addr,pcm1_addr;wire [1:0] pcm_cs,pcm_ok;wire [7:0] pcm0_data,pcm1_data;
wire [31:0] pcm0_block,pcm1_block;
wire signed [15:0] audio;wire sample_valid;
`ifdef SPY_SOUND_INTEGRATED
spy_sound u_sound(.clk(clk_sys),.reset(game_reset||game_watchdog),.pause(paused),.main_latch(sound_latch),.main_irq(sound_irq),
    .rom_req(sound_cs),.rom_addr(sound_addr),.rom_data(sound_data),.rom_ok(sound_ok),.pcm_req(pcm_cs),
    .pcm0_addr(pcm0_addr),.pcm1_addr(pcm1_addr),.pcm0_data(pcm0_data),.pcm1_data(pcm1_data),.pcm0_block(pcm0_block),.pcm1_block(pcm1_block),.pcm_ok(pcm_ok),.audio(audio),.sample_valid(sample_valid));
`else
assign {sound_addr,sound_cs,pcm0_addr,pcm1_addr,pcm_cs,audio,sample_valid}=0;
`endif
spy_roms #(.GFX_RESET_INPUT(1)) u_roms(.gfx_reset(game_reset||game_watchdog),.clk(clk_sys),.clk_sdram(clk_sdram),.reset(global_reset),.rfsh(game_reset?startup_hb:!lhbl),.downloading(ioctl_download),.ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index),.ioctl_data(ioctl_dout),.ioctl_addr(ioctl_addr),.ioctl_wait(ioctl_wait),.image_ready(image_ready),.load_error(load_error),
    .main_addr(main_addr),.main_cs(main_cs),.main_data(main_data),.main_ok(main_ok),
    .f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.o_addr(o_addr),.f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),.o_cs(o_cs),
    .f_data(f_data),.a_data(a_data),.b_data(b_data),.o_data(o_data),.f_ok(f_ok),.a_ok(a_ok),.b_ok(b_ok),.o_ok(o_ok),
    .sound_addr(sound_addr),.sound_cs(sound_cs),.sound_data(sound_data),.sound_ok(sound_ok),.pcm0_addr(pcm0_addr),.pcm1_addr(pcm1_addr),
    .pcm_cs(pcm_cs),.pcm0_data(pcm0_data),.pcm1_data(pcm1_data),.pcm0_block(pcm0_block),.pcm1_block(pcm1_block),.pcm_ok(pcm_ok),
    .sdram_dq(SDRAM_DQ),.sdram_a(SDRAM_A),.sdram_ba(SDRAM_BA),.sdram_dqml(SDRAM_DQML),.sdram_dqmh(SDRAM_DQMH),
    .sdram_nwe(SDRAM_nWE),.sdram_ncas(SDRAM_nCAS),.sdram_nras(SDRAM_nRAS),.sdram_ncs(SDRAM_nCS),.sdram_cke(SDRAM_CKE));
`ifdef SPY_HISCORE_VALIDATED
wire hs_read,hs_write;
spy_hiscore #(.HS_ADDRESSWIDTH(13)) u_hiscore(.clk(clk_sys),.reset(game_reset||game_watchdog),.paused(paused&&(!state_req||state_grant)),.autosave(!status[11]),
    .ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr[24:0]),.ioctl_index(ioctl_index),.OSD_STATUS(OSD_STATUS),.data_from_hps(ioctl_dout),.data_from_ram(state_dout),
    .ram_address(state_addr),.data_to_hps(ioctl_din),.data_to_ram(state_din),.ram_write(state_we),
    .ram_intent_read(hs_read),.ram_intent_write(hs_write),.pause_cpu(hs_pause),.configured(hs_configured));
assign state_req=hs_read||hs_write;
`else
assign {hs_pause,hs_configured,hs_upload_req,ioctl_din,state_addr,state_din,state_req,state_we}=0;
`endif
wire adjusted_ce,adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb;
wire [7:0] adjusted_r,adjusted_g,adjusted_b;
wire [4:0] size_code=status[37:33];
wire signed [4:0] hsize=size_code<=6?$signed(size_code):size_code<=16?$signed(size_code-5'd17):5'sd0;
spy_geometry u_geometry(.clk(clk_sys),.reset(global_reset),.ce_in(game_reset?startup_ce:ce_pix),.active(status[32]),.hsize(hsize),
    .hposition($signed(status[42:38])),.vposition($signed(status[47:43])),.red_in(game_reset?8'd0:red),.green_in(game_reset?8'd0:green),.blue_in(game_reset?8'd0:blue),
    .hs_in(game_reset?startup_hs:hs),.vs_in(game_reset?startup_vs:vs),.hblank_in(game_reset?startup_hb:!lhbl),.vblank_in(game_reset?startup_vb:!lvbl),.ce_out(adjusted_ce),.hs_out(adjusted_hs),.vs_out(adjusted_vs),
    .hblank_out(adjusted_hb),.vblank_out(adjusted_vb),.red_out(adjusted_r),.green_out(adjusted_g),.blue_out(adjusted_b));
wire [7:0] credits_r,credits_g,credits_b;
wire credits_hs,credits_vs,credits_hb,credits_vb;
wire [1:0] credits_rotation = rotation == 2'd2 ? 2'd3 : rotation == 2'd3 ? 2'd2 : rotation;
credits_overlay #(.WIDTH(304),.HEIGHT(224),.SCALE_LOG2(0),.SCROLL_FRAMES(4)) u_credits(
    .clk_video(clk_sys),.reset(global_reset),.ce_pixel(adjusted_ce),.menu_trigger(status[120]),
    .dismiss((|(joystick_0|joystick_1)) || (|buttons) || ps2_key[9] || OSD_STATUS),.rotation(credits_rotation),
    .r_in(adjusted_r),.g_in(adjusted_g),.b_in(adjusted_b),.hs_in(adjusted_hs),.vs_in(adjusted_vs),
    .hblank_in(adjusted_hb),.vblank_in(adjusted_vb),.r_out(credits_r),.g_out(credits_g),.b_out(credits_b),
    .hs_out(credits_hs),.vs_out(credits_vs),.hblank_out(credits_hb),.vblank_out(credits_vb),.de_out(),.active());
wire mixed_de;
arcade_video #(.WIDTH(304),.DW(24)) u_video(.clk_video(clk_sys),.ce_pix(adjusted_ce),.RGB_in({credits_r,credits_g,credits_b}),
    .HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(mixed_de),.VGA_SL(VGA_SL),
    .fx(direct_video?3'd0:status[14:12]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
wire rotate90=rotation==1||rotation==2;
wire [1:0] aspect=direct_video?2'd0:status[122:121];
wire [12:0] native_arx,native_ary,rotated_arx,rotated_ary;
video_freak u_scale(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE_IN(mixed_de),.VGA_DE(VGA_DE),.VIDEO_ARX(native_arx),.VIDEO_ARY(native_ary),
    .ARX(aspect==0?12'd4:{10'd0,aspect}-12'd1),.ARY(aspect==0?12'd3:12'd0),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(rotate90?3'd0:image_scale));
`ifdef MISTER_FB
wire rotate_fb_en,rotate_write,rotate_overflow;
wire [28:0] rotate_addr;wire [63:0] rotate_data;wire [7:0] rotate_be;
video_scale_int u_rotated_scale(.CLK_VIDEO(CLK_VIDEO),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
    .SCALE(rotate90?image_scale:3'd0),.hsize(FB_WIDTH),.vsize(FB_HEIGHT),
    .arx_i(native_ary!=0?native_ary[11:0]:native_arx[11:0]),.ary_i(native_ary!=0?native_arx[11:0]:12'd0),.arx_o(rotated_arx),.ary_o(rotated_ary));
screen_rotate u_rotate(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
    .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),.rotate_ccw(rotation==2),.no_rotate(!rotate90),.flip(rotation==3),.video_rotated(),
    .FB_EN(rotate_fb_en),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL),.FB_LL(FB_LL),.DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(rotate_addr),.DDRAM_DIN(rotate_data),.DDRAM_BE(rotate_be),.DDRAM_WE(rotate_write),.DDRAM_RD(DDRAM_RD));
spy_ddr_write_fifo u_rotate_writes(.clk(clk_sys),.reset(game_reset),.in_valid(rotate_write),
    .in_addr(rotate_addr),.in_data(rotate_data),.in_be(rotate_be),.busy(DDRAM_BUSY),
    .out_valid(DDRAM_WE),.out_addr(DDRAM_ADDR),.out_data(DDRAM_DIN),.out_be(DDRAM_BE),.overflow(rotate_overflow));
assign FB_EN=rotate_fb_en&&!rotate_overflow;
assign FB_FORCE_BLANK=game_reset||rotate_overflow;
`else
assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_RD,DDRAM_WE}=0;
assign {rotated_arx,rotated_ary}=0;
wire rotate_overflow=1'b0;
`endif
assign VIDEO_ARX=rotate90?rotated_arx:native_arx;assign VIDEO_ARY=rotate90?rotated_ary:native_ary;
assign AUDIO_S=1;assign AUDIO_L=paused?16'd0:audio;assign AUDIO_R=paused?16'd0:audio;assign AUDIO_MIX=0;
assign HDMI_FREEZE=paused;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
assign LED_USER=ioctl_download||load_error||rotate_overflow;assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
assign ADC_BUS='Z;assign USER_OUT='1;assign {UART_RTS,UART_TXD,UART_DTR}=0;assign {SD_SCK,SD_MOSI,SD_CS}='Z;
