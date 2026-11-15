// SPDX-License-Identifier: GPL-3.0-or-later
module emu(
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='Z;assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
    assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
    assign AUDIO_S=1;assign AUDIO_MIX=0;
    `include "build_id.v"
    localparam CONF_STR={
        "SteelForce;;",
        // Grouped like the other MeatCore arcade cores: Video / Audio / Game submenus, then Credits and Reset.
        // Status bits are unchanged. No DIP page: both games keep their settings in the Service-mode EEPROM.
        "P1,Video Settings;",
        "P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "P1O[12:10],Scaling,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
        "P1O[14:13],Vertical crop,None,224,216,200;",
        "P1O[16:15],HDMI rotation,None,CW,CCW;",
        "P1O[20],Flip screen,Off,On;",
        "P1O[4:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
        "P1-;",
        // CRT Adjust as in the Darkmist core (rtl/steel_crt.sv): the sub-options show only while it is On (status_menumask bit 1).
        "P1O[30],CRT Adjust,Off,On;",
        "H1P1O[32:31],CRT H-Size,0,+1,-2,-1;",
        "H1P1O[37:33],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H1P1O[42:38],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P2,Audio Settings;",
        "P2O[19:18],Audio gain,100%,50%,25%,Mute;",
        "P2O[22:21],Audio filter,Enhanced,MAME,Raw PCB DAC;",
        "P2O[24:23],Treble exciter,Medium,Off,Low,High;",
        "P3,Game Settings;",
        "P3O[6],Service mode,Off,On;",
        "P3O[43],CPU Turbo (no slowdown),Off,On;",
        "P3-;",
        "P3O[8],NVRAM autosave,On,Off;",
        "P3T[9],Save NVRAM;",
        "-;",
        "R[29],Credits;",
        "-;",
        "R[0],Reset;",
        "J1,Fire/Accelerate,Grenade,-,-,-,-,Start,Coin,Pause,Service;",
        "v,1;V,v",`BUILD_DATE
    };
    wire clk_sys,clk_ram,pll_locked;
    steel_pll pll(.refclk(CLK_50M),.clk(clk_sys),.ram_clk(clk_ram),.locked(pll_locked));
    reg [2:0] reset_pipe=3'b111;
    always @(posedge clk_sys or negedge pll_locked)begin
        if(!pll_locked)reset_pipe<=3'b111;
        else reset_pipe<={reset_pipe[1:0],RESET};
    end
    wire power_reset=|reset_pipe;
    wire [127:0] status;
    wire [1:0] buttons;
    wire [31:0] joystick_0,joystick_1,joystick_2,joystick_3,joystick_4,joystick_5;
    wire [10:0] ps2_key;
    wire [24:0] ps2_mouse;
    wire forced_scandoubler,direct_video;
    wire [21:0] gamma_bus;
    wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,ioctl_wait,ioctl_upload_req;
    wire [15:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [7:0] ioctl_from_hps,ioctl_to_hps,ioctl_upload_index;
    wire hps_download,hps_wr,hps_wait;
    wire [15:0] hps_index;
    wire [26:0] hps_addr;
    wire [7:0] hps_dout;
    wire rom_ddr_rd;
    wire [28:0] rom_ddr_addr;
    wire video_rotated;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps_io(
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
        .buttons(buttons),.status(status),.status_in(128'b0),.status_set(1'b0),.status_menumask({14'd0,!status[30],1'b0}),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.joystick_2(joystick_2),.joystick_3(joystick_3),.joystick_4(joystick_4),.joystick_5(joystick_5),
        .ps2_key(ps2_key),.ps2_mouse(ps2_mouse),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
        .video_rotated(video_rotated),.new_vmode(1'b0),.info_req(1'b0),.info(8'b0),
        .ioctl_download(hps_download),.ioctl_upload(ioctl_upload),
        .ioctl_wr(hps_wr),.ioctl_rd(ioctl_rd),.ioctl_addr(hps_addr),.ioctl_index(hps_index),
        .ioctl_dout(hps_dout),.ioctl_din(ioctl_to_hps),.ioctl_wait(hps_wait),
        .ioctl_upload_req(ioctl_upload_req),.ioctl_upload_index(ioctl_upload_index));
    reg mortalr=0,boot_hold=1,pause_button_last=0,user_pause=0;
    wire image_valid,image_mortalr,download_active,storage_error,nv_error;
    always @(posedge clk_sys)begin
        pause_button_last<=status[7];
        if(power_reset)begin mortalr<=0;boot_hold<=1;user_pause<=0;end
        else begin
            if(ioctl_download && ioctl_wr && ioctl_index==1 && ioctl_addr==0)begin
                mortalr<=ioctl_from_hps[0];boot_hold<=1;
            end
            if(ioctl_download && ioctl_wr && ioctl_index==5 && ioctl_addr==0 &&
                ioctl_from_hps==1 && image_valid && !storage_error)boot_hold<=0;
            if(status[0] || buttons[1])user_pause<=0;
            else if(status[7] && !pause_button_last)user_pause<=!user_pause;
        end
    end
    wire [23:0] rgb;
    wire ce_pixel,hs,vs,hblank,vblank;
    wire signed [13:0] audio;
    wire audio_sample;
    wire sdram_drive;
    wire [15:0] sdram_data_out;
    wire [1:0] sdram_dqm;
    steel_mister_board board(
        .clk(clk_sys),.power_reset(power_reset),.game_reset(status[0] || buttons[1]),
        .boot_hold(boot_hold),.mortalr(mortalr),.pause_cpu(user_pause),.cpu_turbo(status[43]),
        .flip_screen(status[20]),.crt_h_shift(5'd0),.crt_v_shift(5'd0),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.osd_status(OSD_STATUS),
        .service_button(status[6]),.nv_autosave(!status[8]),.nv_save_button(status[9]),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_din(ioctl_from_hps),
        .ioctl_dout(ioctl_to_hps),.ioctl_wait(ioctl_wait),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(ioctl_upload_index),.rgb(rgb),.ce_pixel(ce_pixel),.hs(hs),.vs(vs),
        .hblank(hblank),.vblank(vblank),.audio(audio),.audio_sample(audio_sample),
        .image_valid(image_valid),.image_mortalr(image_mortalr),.download_active(download_active),
        .storage_error(storage_error),.nv_initialized(),.nv_dirty(),.nv_error(nv_error),.hs_configured(),.missed_lines(),
        .sdram_address(SDRAM_A),.sdram_bank(SDRAM_BA),.sdram_dqm(sdram_dqm),
        .sdram_cs_n(SDRAM_nCS),.sdram_ras_n(SDRAM_nRAS),.sdram_cas_n(SDRAM_nCAS),.sdram_we_n(SDRAM_nWE),
        .sdram_drive(sdram_drive),.sdram_data_out(sdram_data_out),.sdram_data_in(SDRAM_DQ));
    // Fast ROM load: the MRA gives ROM index 0 address 0x30000000, Main memcpy's the image into DDR3
    // and announces only its length; steel_ddr_rom replays it into the unchanged byte loader path
    // (Main's byte handshake streams ~1 MB/s, so the 6.8 MB image took ~7 s). Byte streams pass through.
    steel_ddr_rom ddr_rom(.clk(clk_sys),.reset(power_reset),
        .hps_download(hps_download),.hps_wr(hps_wr),.hps_index(hps_index),.hps_addr(hps_addr),.hps_dout(hps_dout),.hps_wait(hps_wait),
        .download(ioctl_download),.wr(ioctl_wr),.index(ioctl_index),.addr(ioctl_addr),.dout(ioctl_from_hps),
        .core_wait(ioctl_wait),.image_ready(image_valid),.load_error(storage_error),
        .ddr_busy(DDRAM_BUSY),.ddr_rd(rom_ddr_rd),.ddr_addr(rom_ddr_addr),.ddr_dout(DDRAM_DOUT),.ddr_dout_ready(DDRAM_DOUT_READY));
    assign SDRAM_CKE=1;assign {SDRAM_DQMH,SDRAM_DQML}=sdram_dqm;
    assign SDRAM_DQ=sdram_drive ? sdram_data_out : 16'hzzzz;
    altddio_out #(.width(1),.power_up_high("OFF"),.oe_reg("UNREGISTERED"),
        .extend_oe_disable("OFF"),.intended_device_family("Cyclone V")) ram_clock_pin(
        .outclock(clk_ram),.outclocken(1'b1),.aclr(1'b0),.aset(1'b0),
        .datain_h(1'b1),.datain_l(1'b0),.dataout(SDRAM_CLK),.oe(1'b1));
    assign LED_USER=download_active || boot_hold || storage_error || nv_error;
    // OKI output path. Audio filter: Enhanced (flat windowed-sinc interpolation), MAME (0.289 LOFI
    // interpolator) or Raw PCB DAC (held ~7.6 kHz samples). The treble exciter applies to the first two.
    wire signed [15:0] audio_smooth,audio_excited;
    wire audio_smooth_valid;
    wire [1:0] audio_filter=status[22:21];
    wire [1:0] exciter_level=status[24:23]==2'd0 ? 2'd2 : status[24:23]==2'd1 ? 2'd0 : status[24:23]==2'd2 ? 2'd1 : 2'd3;
    steel_audio_upsample audio_upsample(.clk(clk_sys),.reset(power_reset),.sample(audio_sample),.pcm(audio),
        .bank(audio_filter==2'd1),.out(audio_smooth),.out_valid(audio_smooth_valid));
    steel_audio_exciter audio_exciter(.clk(clk_sys),.reset(power_reset),.valid(audio_smooth_valid),.x(audio_smooth),
        .level(exciter_level),.y(audio_excited));
    wire signed [15:0] audio_feed=audio_filter[1] ? {{2{audio[13]}},audio} : audio_excited;
    steel_audio_output audio_output(.pcm(audio_feed),.gain(status[19:18]),.pcm16(AUDIO_L));
    assign AUDIO_R=AUDIO_L;
    // MeatCore Credits (credits/, docs: INTEGRATION.md): inserted on the native raster, after the native flip and before the
    // mixer/scandoubler and screen_rotate, with RGB, sync and blanking together; same clock and pixel enable. Raw HPS inputs are only observed.
    // CRT Adjust (H-Size / H-Position / V-Shift, Darkmist-style): native sync, picture re-read from a line buffer.
    // Off is a pure bypass of the native stream. The credits overlay draws on the picture actually shown.
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hb,crt_vb,crt_ce,crt_active;
    steel_crt crt(.clk(clk_sys),.reset(power_reset),.ce_in(ce_pixel),.enable(status[30]),
        .hsize_option(status[32:31]),.hpos_option(status[37:33]),.vpos_option(status[42:38]),
        .r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),.hs_in(hs),.vs_in(vs),.hb_in(hblank),.vb_in(vblank),
        .ce_out(crt_ce),.active(crt_active),.r_out(crt_r),.g_out(crt_g),.b_out(crt_b),
        .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.read_period());
    wire ov_ce=crt_active ? crt_ce : ce_pixel;
    wire [7:0] ov_r=crt_active ? crt_r : rgb[23:16];
    wire [7:0] ov_g=crt_active ? crt_g : rgb[15:8];
    wire [7:0] ov_b=crt_active ? crt_b : rgb[7:0];
    wire ov_hs=crt_active ? crt_hs : hs;
    wire ov_vs=crt_active ? crt_vs : vs;
    wire ov_hb=crt_active ? crt_hb : hblank;
    wire ov_vb=crt_active ? crt_vb : vblank;
    wire [7:0] credits_r,credits_g,credits_b;
    wire credits_hs,credits_vs,credits_hb,credits_vb,credits_de,credits_active;
    wire credits_dismiss=|(joystick_0|joystick_1|joystick_2|joystick_3|joystick_4|joystick_5)|(|buttons)|ps2_key[9]|(|ps2_mouse[2:0])|OSD_STATUS;
    // Steel Force and Mortal Race are horizontal games: the credits are fixed horizontal (rotation 0) regardless of the
    // HDMI rotation option. A constant also lets Quartus prune the overlay's rotation hardware.
    wire [1:0] credits_rotation=2'd0;
    credits_overlay #(.WIDTH(366),.HEIGHT(240)) credits(
        .clk_video(clk_sys),.reset(power_reset),.ce_pixel(ov_ce),.menu_trigger(status[29]),.dismiss(credits_dismiss),
        .rotation(credits_rotation),.r_in(ov_r),.g_in(ov_g),.b_in(ov_b),.hs_in(ov_hs),.vs_in(ov_vs),
        .hblank_in(ov_hb),.vblank_in(ov_vb),.r_out(credits_r),.g_out(credits_g),.b_out(credits_b),
        .hs_out(credits_hs),.vs_out(credits_vs),.hblank_out(credits_hb),.vblank_out(credits_vb),.de_out(credits_de),.active(credits_active));
    // Scandoubler Fx: None, CRT 25/50/75 percent. arcade_video's fx 1 selects HQ2x, so the menu value n maps to fx n+1 and fx 1 is never
    // produced: the hq2x select is a constant 0 and Quartus removes the hq2x block.
    wire [2:0] scan_fx=status[4:3]==0 ? 3'd0 : {1'b0,status[4:3]}+3'd1;
    wire [7:0] av_r,av_g,av_b;
    wire av_hs,av_vs,av_de,av_ce;
    arcade_video #(.WIDTH(366),.DW(24)) video(
        .clk_video(clk_sys),.ce_pix(ov_ce),.RGB_in({credits_r,credits_g,credits_b}),.HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(av_ce),.VGA_R(av_r),.VGA_G(av_g),.VGA_B(av_b),
        .VGA_HS(av_hs),.VGA_VS(av_vs),.VGA_DE(av_de),.VGA_SL(VGA_SL),
        .fx(scan_fx),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
    assign CE_PIXEL=av_ce;assign VGA_R=av_r;assign VGA_G=av_g;assign VGA_B=av_b;
    assign VGA_HS=av_hs;assign VGA_VS=av_vs;
    wire [1:0] ar=status[2:1];
    wire [11:0] crop=status[14:13]==0 ? 12'd0 : status[14:13]==1 ? 12'd224 : status[14:13]==2 ? 12'd216 : 12'd200;
    video_freak framing(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(av_ce),.VGA_VS(av_vs),
        .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.VGA_DE(VGA_DE),
        .VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),.VGA_DE_IN(av_de),
        .ARX(ar==0 ? (video_rotated ? 12'd3 : 12'd4) : {10'b0,ar}-12'd1),
        .ARY(ar==0 ? (video_rotated ? 12'd4 : 12'd3) : 12'd0),
        .CROP_SIZE(crop),.CROP_OFF(5'b0),.SCALE(status[12:10]));
    wire rot_ddr_we;
    wire [7:0] rot_ddr_burstcnt,rot_ddr_be;
    wire [28:0] rot_ddr_addr;
    wire [63:0] rot_ddr_din;
`ifdef MISTER_FB
    assign FB_FORCE_BLANK=0;
    screen_rotate rotation(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(av_ce),
        .VGA_R(av_r),.VGA_G(av_g),.VGA_B(av_b),.VGA_HS(av_hs),.VGA_VS(av_vs),.VGA_DE(VGA_DE),
        .rotate_ccw(status[16:15]==2),.no_rotate(status[16:15]==0 || direct_video),.flip(1'b0), // flip is native (steel_raster), HDMI rotates the already flipped stream
       
        .video_rotated(video_rotated),.FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
        .DDRAM_CLK(),.DDRAM_BUSY(DDRAM_BUSY || rom_ddr_rd),.DDRAM_BURSTCNT(rot_ddr_burstcnt),
        .DDRAM_ADDR(rot_ddr_addr),.DDRAM_DIN(rot_ddr_din),.DDRAM_BE(rot_ddr_be),.DDRAM_WE(rot_ddr_we),.DDRAM_RD());
`else
    assign video_rotated=0;
    assign {rot_ddr_burstcnt,rot_ddr_addr,rot_ddr_din,rot_ddr_be,rot_ddr_we}=0;
`endif
    // DDRAM is shared per request: the ROM replay read wins (single-beat), the rotation writer
    // (burst length 1) sees BUSY while a read is presented. Both run on clk_sys (CLK_VIDEO).
    assign DDRAM_CLK=clk_sys;
    assign DDRAM_BURSTCNT=rom_ddr_rd ? 8'd1 : rot_ddr_burstcnt;
    assign DDRAM_ADDR=rom_ddr_rd ? rom_ddr_addr : rot_ddr_addr;
    assign DDRAM_DIN=rot_ddr_din;
    assign DDRAM_BE=rom_ddr_rd ? 8'hff : rot_ddr_be;
    assign DDRAM_RD=rom_ddr_rd;
    assign DDRAM_WE=rot_ddr_we && !rom_ddr_rd;
endmodule
