// SPDX-License-Identifier: GPL-3.0-or-later
// Prototype real game/storage integration. Raw MRA, hiscore, CRT adjustment and
// physical timing qualification remain open. Index zero uses the packed image.
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='Z;assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
    assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
    assign AUDIO_S=1;assign AUDIO_MIX=0;
    assign FB_FORCE_BLANK=0;
    `include "build_id.v"
    localparam CONF_STR={
        "Darkmist;;",
        "P1,Video Settings;",
        "P3,Game Settings;",
        "-;",
        "DIP;",
        "R[120],Credits;",
        "-;",
        "R[0],Reset;",
        "H0P1O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "H0P1O[7:6],Rotation,90 CCW,Native,90 CW,180;",
        "H0P1O[5:4],Scaling,Normal,V-Integer,HV-Integer,HV-Integer-;",
        "H4P1O[3],HV Integer rounding,Down,Up;",
        "H0P1O[11:9],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
        "P1-;",
        "P1O[16],CRT Adjust,Off,On;",
        "H3P1O[30],Direct video180,Off,On;",
        "H1P1O[19:17],CRT H-Size,0,+1,+2,-2,-1;",
        "H1P1O[24:20],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H1P1O[29:25],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P3O[12],Autosave Hi-Score,On,Off;",
        "P3O[32],Pause When OSD Open,On,Off;",
        "J1,Sword,Magic,Start 1P,Start 2P,Coin 1,Coin 2,Service Mode,Pause;",
        "jn,A,B,Start,R,Select,L,X,Y;v,1;V,v",`BUILD_DATE
    };
    wire clk_game,clk_sdram,pll_locked;
    darkmist_pll core_pll(.refclk(CLK_50M),.clk_game(clk_game),.clk_sdram(clk_sdram),.locked(pll_locked));
    reg [1:0] lock_sync=0;
    always @(posedge clk_game) lock_sync<={lock_sync[0],pll_locked};
    wire power_reset=!lock_sync[1];
    wire host_reset;
    // RESET originates in sysmem. Assert immediately; release on game edges.
    // OSD_STATUS is already clk_game via hps_io HPS_BUS[36]; preserve its path.
    darkmist_host_controls host_controls (
        .clk_game(clk_game),.async_reset(power_reset || RESET),
        .async_osd_status(1'b0),.reset_game(host_reset),.osd_game()
    );
    altddio_out #(.width(1),.intended_device_family("Cyclone V")) sdram_clock (
        .outclock(clk_sdram),.datain_h(1'b1),.datain_l(1'b0),.dataout(SDRAM_CLK),
        .outclocken(1'b1),.oe(1'b1),.aclr(1'b0),.aset(1'b0),.sclr(1'b0),.sset(1'b0)
    );
    wire [127:0] status;
    wire [1:0] buttons;
    wire [31:0] joystick_0,joystick_1,joystick_2,joystick_3,joystick_4,joystick_5;
    wire [10:0] ps2_key;
    wire [24:0] ps2_mouse;
    wire [21:0] gamma_bus;
    wire forced_scandoubler,direct_video,ioctl_download,ioctl_wr;
    wire ioctl_upload,hs_upload_req,hs_pause,game_paused,hs_access,hs_we;
    wire [11:0] hs_addr;
    wire [7:0] hs_din,hs_data,hs_read;
    wire [15:0] ioctl_index;
    wire [7:0] ioctl_dout;
    wire [26:0] ioctl_addr;
    wire storage_wait;
    darkmist_hps_io #(.CONF_STR(CONF_STR)) hps_io (
        .clk_sys(clk_game),.metrics_reset(host_reset),.HPS_BUS(HPS_BUS),.EXT_BUS(),.status(status),.buttons(buttons),
        .joystick_0(joystick_0),.joystick_1(joystick_1),.gamma_bus(gamma_bus),
        .joystick_2(joystick_2),.joystick_3(joystick_3),.joystick_4(joystick_4),.joystick_5(joystick_5),
        .ps2_key(ps2_key),.ps2_mouse(ps2_mouse),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
        .status_menumask({11'd0,(direct_video || status[5:4]!=3),!direct_video,(!status[16] || direct_video),!status[16],direct_video}),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
        .ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),
        .ioctl_upload_index(8'd4),.ioctl_din(hs_din),
        .ioctl_wait(ioctl_index==0 && ioctl_download && storage_wait)
    );
    reg [7:0] dips[0:1];
    initial begin dips[0]=8'hff;dips[1]=8'h7f;end
    always @(posedge clk_game) if(ioctl_wr && ioctl_index==254 && ioctl_addr<2)
        dips[ioctl_addr[0]]<=ioctl_dout;
    reg pause_toggle=0,service_toggle=0,pause_old=0,service_old=0;
    wire pause_button=joystick_0[11] || joystick_1[11];
    wire service_button=joystick_0[10] || joystick_1[10];
    always @(posedge clk_game) begin
        pause_old<=pause_button;service_old<=service_button;
        if(power_reset) begin pause_toggle<=0;service_toggle<=0;end
        else begin
            if(pause_button && !pause_old) pause_toggle<=!pause_toggle;
            if(service_button && !service_old) service_toggle<=!service_toggle;
        end
    end
    wire [7:0] p1=~{2'b00,joystick_0[5:4],joystick_0[0],joystick_0[1],joystick_0[2],joystick_0[3]};
    wire [7:0] p2=~{2'b00,joystick_1[5:4],joystick_1[0],joystick_1[1],joystick_1[2],joystick_1[3]};
    wire start1=joystick_0[6] || joystick_1[6];
    wire start2=joystick_0[7] || joystick_1[7];
    wire [7:0] starts=~{3'b000,start2,start1,3'b000};
    wire [7:0] dip1={dips[0][7:6],dips[0][5] && !service_toggle,dips[0][4:0]};
    wire loaded,ready,load_error,game_reset,hold_game,ce_native,frame_tick;
    wire [8:0] display_x;
    wire [7:0] display_y;
    wire hblank,vblank,hsync,vsync;
    wire service_reset_request;
    darkmist_service_reset service_reset (
        .clk(clk_game),.power_reset(power_reset),.run_ready(loaded && ready),
        .downloading(ioctl_download && ioctl_index==0),.service_n(dip1[5]),
        .reset_request(service_reset_request)
    );
    darkmist_video_timing timing (
        .clk(clk_game),.power_reset(power_reset),.soft_reset(host_reset || status[0] || buttons[1] || service_reset_request),
        .run_ready(loaded && ready),.hold_game(hold_game),.ce_pixel(ce_native),
        .pixel_x(display_x),.pixel_y(display_y),.hblank(hblank),.vblank(vblank),
        .hsync(hsync),.vsync(vsync),.frame_tick(frame_tick)
    );
    reg [1:0] coin_old=0;
    reg [1:0] coin_ticks[0:1];
    initial begin coin_ticks[0]=0;coin_ticks[1]=0;end
    wire [1:0] coin_buttons={joystick_0[9] || joystick_1[9],joystick_0[8] || joystick_1[8]};
    always @(posedge clk_game) begin
        coin_old<=coin_buttons;
        for(integer c=0;c<2;c=c+1) begin
            if(power_reset) coin_ticks[c]<=0;
            else if(coin_buttons[c] && !coin_old[c]) coin_ticks[c]<=2;
            else if(frame_tick && coin_ticks[c]!=0) coin_ticks[c]<=coin_ticks[c]-2'd1;
        end
    end
    wire [11:0] game_rgb;
    wire [15:0] left,right;
    wire game_audio_sample;
    wire [15:0] mono;
    wire renderer_error;
    darkmist_hiscore scores(
        .clk(clk_game),.reset(game_reset),.paused(game_paused),.autosave(!status[12]),
        .service_mode(!dip1[5]),.OSD_STATUS(OSD_STATUS),.ioctl_upload(ioctl_upload),.ioctl_upload_req(hs_upload_req),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr[24:0]),
        .ioctl_index(ioctl_index),.data_from_hps(ioctl_dout),.data_to_hps(hs_din),
        .data_from_ram(hs_read),.pause_cpu(hs_pause),.hs_access(hs_access),.hs_we(hs_we),
        .hs_addr(hs_addr),.hs_data(hs_data)
    );
    darkmist_system game (
        .clk(clk_game),.clk_capture(clk_sdram),.reset(power_reset),.cpu_reset(hold_game),.pause(pause_toggle || (OSD_STATUS && !status[32]) || hs_pause),.paused(game_paused),
        .display_flip(direct_video ? status[30] : status[7:6]==3),
        .hs_access(hs_access),.hs_we(hs_we),.hs_addr(hs_addr),.hs_data(hs_data),
        .download(ioctl_download && ioctl_index==0),.prog_we(ioctl_wr && ioctl_index==0),
        .prog_addr(ioctl_addr[19:0]),.prog_data(ioctl_dout),.prog_wait(storage_wait),
        .loaded(loaded),.ready(ready),.load_error(load_error),.game_reset(game_reset),
        .p1(p1),.p2(p2),.starts(starts),.dip1(dip1),.dip2(dips[1]),.unknown_inputs(8'hff),
        .coins({coin_ticks[1]!=0,coin_ticks[0]!=0}),.video_region(3'd0),.video_addr(12'd0),.debug_addr(12'd0),
        .video_data(),.debug_data(hs_read),.hardware_control(),.sprite_bank(),
        .audio_left(left),.audio_right(right),.audio_sample(game_audio_sample),
        .trace_main_write(),.trace_sound_write(),.trace_sound_io(),.trace_main_addr(),.trace_sound_addr(),
        .trace_main_data(),.trace_sound_data(),.main_cpu_addr(),.sound_cpu_addr(),.sound_irq_state(),
        .unknown_port40(),.unknown_port50(),.sound_io_read(),.sound_irq_ack(),.sound_fetch(),
        .sound_bus_cen(),.sound_cpu_din(),.ce_pixel(),.raster_x(),.raster_y(),
        .rgb(game_rgb),.pixel_ce(),.pixel_valid(),.pixel_x(),.pixel_y(),
        .underflow_lines(),.overrun_lines(),.maximum_line_clocks(),.unknown_sprite_seen(),.video_protocol_error(renderer_error),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nWE(SDRAM_nWE),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCS(SDRAM_nCS),.SDRAM_CKE(SDRAM_CKE)
    );
    darkmist_audio_out audio_out (
        .clk(clk_game),.rst(power_reset),.sample(game_audio_sample),
        .left_in(left),.right_in(right),.mono_out(mono)
    );
    // The PCB output is one bridged mono channel (no stereo option; reviewed audio path).
    assign AUDIO_L=(game_reset || game_paused) ? 16'd0 : mono;
    assign AUDIO_R=(game_reset || game_paused) ? 16'd0 : mono;
    assign LED_USER=ioctl_download || load_error || renderer_error;
    wire video_de;
    wire [11:0] video_rgb=game_reset ? 12'd0 : game_rgb;
    wire [7:0] game_r={video_rgb[11:8],video_rgb[11:8]};
    wire [7:0] game_g={video_rgb[7:4],video_rgb[7:4]};
    wire [7:0] game_b={video_rgb[3:0],video_rgb[3:0]};
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hb,crt_vb,crt_ce,crt_active;
    darkmist_crt crt (
        .clk(clk_game),.reset(power_reset || !loaded),.ce_in(ce_native),.enable(status[16]),
        .hsize_option(status[19:17]),
        .hpos_option(status[24:20]),.vpos_option(status[29:25]),
        .r_in(game_r),.g_in(game_g),.b_in(game_b),
        .hs_in(hsync),.vs_in(vsync),.hb_in(hblank),.vb_in(vblank),
        .ce_out(crt_ce),.active(crt_active),.r_out(crt_r),.g_out(crt_g),.b_out(crt_b),
        .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.read_period()
    );
    // The credits overlay draws on the picture actually shown: CRT-adjusted when CRT Adjust is on.
    wire ov_ce=crt_active ? crt_ce : ce_native;
    wire [7:0] ov_r=crt_active ? crt_r : game_r;
    wire [7:0] ov_g=crt_active ? crt_g : game_g;
    wire [7:0] ov_b=crt_active ? crt_b : game_b;
    wire ov_hs=crt_active ? crt_hs : hsync;
    wire ov_vs=crt_active ? crt_vs : vsync;
    wire ov_hb=crt_active ? crt_hb : hblank;
    wire ov_vb=crt_active ? crt_vb : vblank;
    wire [7:0] credits_r,credits_g,credits_b;
    wire credits_hs,credits_vs,credits_hb,credits_vb;
    wire credits_dismiss=|(joystick_0|joystick_1|joystick_2|joystick_3|joystick_4|joystick_5) |
        |buttons | ps2_key[9] | |ps2_mouse[2:0] | OSD_STATUS;
    // Credits are drawn before the screen rotation, in the viewed orientation of the game:
    // status[7:6]=0 90 CCW (default) -> 3; 1 Native -> 0; 2 90 CW -> 1; 3 180 -> 2.
    wire [1:0] credits_rotation = status[7:6]==2'd1 ? 2'd0 : status[7:6]==2'd0 ? 2'd3 :
                                  status[7:6]==2'd2 ? 2'd1 : 2'd2;
    credits_overlay #(.WIDTH(256),.HEIGHT(224),.SCALE_LOG2(0),.SCROLL_FRAMES(4)) credits (
        .clk_video(clk_game),.reset(power_reset),.ce_pixel(ov_ce),
        .menu_trigger(status[120]),.dismiss(credits_dismiss),.rotation(credits_rotation),
        .r_in(ov_r),.g_in(ov_g),.b_in(ov_b),
        .hs_in(ov_hs),.vs_in(ov_vs),.hblank_in(ov_hb),.vblank_in(ov_vb),
        .r_out(credits_r),.g_out(credits_g),.b_out(credits_b),
        .hs_out(credits_hs),.vs_out(credits_vs),.hblank_out(credits_hb),.vblank_out(credits_vb),
        .de_out(),.active());
    darkmist_arcade_video #(.WIDTH(256),.DW(24)) video (
        .clk_video(clk_game),.ce_pix(ov_ce),.RGB_in({credits_r,credits_g,credits_b}),
        .HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(video_de),.VGA_SL(VGA_SL),
        .fx(direct_video ? 3'd0 : status[11:9]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus)
    );
    wire rotate_ccw=status[7:6]==0;
    wire no_rotate=direct_video || status[7:6]==1 || status[7:6]==3;
    wire flip=1'b0; // Native display_flip already serves HDMI, direct and analog.
    wire video_rotated;
    wire [11:0] aspect_x=status[2:1]==0 ? 12'd4 : {10'd0,status[2:1]-2'd1};
    wire [11:0] aspect_y=status[2:1]==0 ? 12'd3 : 12'd0;
    wire [2:0] image_scale=direct_video ? 3'd0 : status[5:4]==2 ? 3'd4 : status[5:4]==3 ? (status[3] ? 3'd3 : 3'd2) : {1'b0,status[5:4]};
    wire [12:0] native_arx,native_ary,rotated_arx,rotated_ary;
    video_freak scaling (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),
        .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.VGA_DE(VGA_DE),
        .VIDEO_ARX(native_arx),.VIDEO_ARY(native_ary),.VGA_DE_IN(video_de),
        .ARX(aspect_x),.ARY(aspect_y),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),
        .SCALE(no_rotate ? image_scale : 3'd0)
    );
    // Apply integer scaling to actual rotated dimensions, as in OSMAN.
    // Custom aspect ARY=0 remains a framework index, not a fraction to swap.
    video_scale_int rotated_scaling (
        .CLK_VIDEO(CLK_VIDEO),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
        .SCALE(no_rotate ? 3'd0 : image_scale),.hsize(FB_WIDTH),.vsize(FB_HEIGHT),
        .arx_i(native_ary!=0 ? native_ary[11:0] : native_arx[11:0]),
        .ary_i(native_ary!=0 ? native_arx[11:0] : 12'd0),
        .arx_o(rotated_arx),.ary_o(rotated_ary)
    );
    assign VIDEO_ARX=no_rotate ? native_arx : rotated_arx;
    assign VIDEO_ARY=no_rotate ? native_ary : rotated_ary;
    // SYS_TOP registers FB_VBL on clk_vid; framebuffer ownership runs here
    // on clk_game. Keep the first asynchronous sample separate from its use.
    (* preserve, ASYNC_REG="TRUE" *) reg [1:0] fb_vbl_sync;
    always @(posedge clk_game) begin
        if(host_reset) fb_vbl_sync<=2'b00;
        else fb_vbl_sync<={fb_vbl_sync[0],FB_VBL};
    end
    darkmist_screen_rotate rotation(.reset(host_reset),.VGA_VS(vsync),.FB_VBL(fb_vbl_sync[1]),.*);
endmodule
