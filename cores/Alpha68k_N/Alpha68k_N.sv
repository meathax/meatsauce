// Alpha68k N MiSTer wrapper around the shared CPU/video/audio/SDRAM system.
// GPL-2.0-or-later, derived from the pinned Template_MiSTer emu interface.
module emu (
`include "sys/emu_ports.vh"
`ifdef ALPHA_EMU_SIM
    ,input wire SIM_MASTER,SIM_SDRAM,SIM_LOCKED
    ,input wire [45:0] SIM_HPS_HOST
    ,output wire SIM_COLD_RESET,SIM_GAME_RESET,SIM_ROM_LOADED,SIM_IOCTL_WAIT,SIM_LOAD_WR
    ,output wire [24:0] SIM_LOAD_ADDR
    ,output wire [15:0] SIM_LOAD_DATA,SIM_SDRAM_DIN,SIM_CONTROLS
    ,output wire [1:0] SIM_COINS
    ,output wire SIM_RAW_CE,SIM_VIDEO_CE,SIM_VIDEO_HB,SIM_VIDEO_VB
    ,output wire [8:0] SIM_RAW_X,SIM_RAW_Y,SIM_VIDEO_Y
    ,output wire [7:0] SIM_VIDEO_X,SIM_PROFILE
    ,output wire [7:0] SIM_DIPS
    ,output wire [23:0] SIM_VIDEO_RGB
    ,output wire [31:0] SIM_MAIN_TX,SIM_UNMAPPED,SIM_DEADLINES,SIM_OVERFLOWS
    ,output wire [11:0] SIM_WORST_LINE
    ,input wire SIM_TEST_HS_ACCESS,SIM_TEST_HS_WRITE
    ,input wire [23:0] SIM_TEST_HS_ADDR
    ,input wire [7:0] SIM_TEST_HS_DATA
    ,output wire [7:0] SIM_HS_DATA
    ,output wire SIM_PAUSED,SIM_HS_CONFIGURED,SIM_HS_REQUEST,SIM_DIRECT_VIDEO
    ,output wire [31:0] SIM_JOY0
    ,output wire SIM_USER_PAUSE
    ,output wire [4:0] SIM_HS_STATE
    ,output wire SIM_HS_RESTORING,SIM_HS_EXTRACTING
`endif
);
    `include "build_id.v"
    localparam CONF_STR = {
        "A68N;;",
        "H0O1,Orientation,Vertical,Horizontal;",
        "H0O[6],Rotate 90,Clockwise,Counter-clockwise;",
        "O[7],Rotate 180,Off,On;",
        "H0O[10:8],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
        "P1,CRT Adjust;",
        "P1O[11],CRT Adjust,Off,On;",
        "H1P1O[14:12],H-Size,0,+1,+2,-2,-1;",
        "H1P1O[19:15],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H1P1O[24:20],V-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H3P1O[27:25],V-Size,0,+1,+2,+3,-3,-2,-1;",
        "H2O[28],Autosave Hiscores,On,Off;",
        "O24,Scandoubler Fx,None,HQ2x,CRT25%,CRT50%,CRT75%;",
        "H0O5,Aspect ratio,Original,Full Screen;",
        "R[120],Credits;",
        "DIP;",
        "O0,Reset,Off,On;",
        "R0,Reset;",
        "J1,Punch,Jump,Start,Coin,Pause;",
        "V,v",`BUILD_DATE
    };
    wire clk_sys,clk_sdram,locked;
`ifdef ALPHA_EMU_SIM
    // Ideal PLL output model only: real HPS/game/framework remain instantiated.
    // The host supplies 48 MHz and the documented SDRAM half-cycle phase.
    assign clk_sys=SIM_MASTER;assign clk_sdram=SIM_SDRAM;assign locked=SIM_LOCKED;
    // External HPS drives only these pins. A direct C++ assignment to the
    // inout port would be overwritten by the core's response drivers.
    assign HPS_BUS[31:16]=SIM_HPS_HOST[31:16];
    assign HPS_BUS[35:33]=SIM_HPS_HOST[35:33];
    assign HPS_BUS[45:38]=SIM_HPS_HOST[45:38];
`else
    alpha68kn_pll pll(.refclk(CLK_50M),.rst(1'b0),
        .clk_sys(clk_sys),.clk_sdram(clk_sdram),.locked(locked));
`endif
    assign SDRAM_CLK=clk_sdram;
    reg [2:0] lock_sync=0,reset_sync=7;
    reg [13:0] power_wait=0;
    always @(posedge clk_sys) begin
        lock_sync<={lock_sync[1:0],locked};
        reset_sync<={reset_sync[1:0],RESET};
        if(!lock_sync[2]) power_wait<=0;
        else if(power_wait!=14'd10000) power_wait<=power_wait+1'b1;
    end
    wire cold_reset=!lock_sync[2] || power_wait!=14'd10000;
    wire [31:0] joy0,joy1,joy2,joy3,joy4,joy5;
    wire [10:0] credits_key;
    wire [24:0] credits_mouse;
    wire [15:0] credits_mouse_ext;
    wire [127:0] status;
    wire [1:0] buttons;
    wire ioctl_download,ioctl_upload,ioctl_upload_req,ioctl_wr;
    wire [7:0] ioctl_din;
    wire hs_configured,hs_pause,hs_read,hs_write_intent,hs_write,paused;
    wire [23:0] hs_addr;
    wire [7:0] hs_to_ram,hs_from_ram;
    reg user_pause=0,pause_button_last=0;
    wire pause_button=joy0[8] || joy1[8];
    // OSD status is used only to dismiss credits; menu opening never pauses.
    // Manual user pause retains the safe hiscore save path.
    reg [1:0] osd_sync=0;
    always @(posedge clk_sys) osd_sync<={osd_sync[0],OSD_STATUS};
    wire pause_game=user_pause || hs_pause;
    always @(posedge clk_sys) begin
        pause_button_last<=pause_button;
        if(game_reset) user_pause<=0;
        else if(pause_button && !pause_button_last) user_pause<=!user_pause;
    end
    wire [26:0] ioctl_addr;
    wire [7:0] ioctl_data;
    wire [15:0] ioctl_index;
    wire ioctl_wait;
    wire forced_scandoubler,direct_video;
    wire [21:0] gamma_bus;
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps (
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.joystick_0(joy0),.joystick_1(joy1),
        .joystick_2(joy2),.joystick_3(joy3),.joystick_4(joy4),.joystick_5(joy5),
        .ps2_key(credits_key),.ps2_mouse(credits_mouse),.ps2_mouse_ext(credits_mouse_ext),
        .status(status),.buttons(buttons),.ioctl_download(ioctl_download),
        .ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_data),
        .ioctl_index(ioctl_index),.ioctl_wait(ioctl_wait),
        .ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(8'd4),.ioctl_din(ioctl_din),
        .status_menumask({12'd0,direct_video || !crt_active,!hs_configured,!crt_active,direct_video}),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),.gamma_bus(gamma_bus)
    );
    wire load=ioctl_download && ioctl_index==0;
    // Standard byte HPS transport serves DIP/hiscore; pair ROM bytes for the
    // existing 16-bit board/SDRAM loader without changing its byte layout.
    reg [7:0] rom_low=0;
    always @(posedge clk_sys) if(load && ioctl_wr && !ioctl_addr[0]) rom_low<=ioctl_data;
    wire load_wr=load && ioctl_wr && ioctl_addr[0];
    wire [24:0] board_load_addr={ioctl_addr[24:1],1'b0};
    wire [15:0] board_load_data={ioctl_data,rom_low};
    // MiSTer DIP bank zero arrives on ioctl index 254, byte address zero.
    // Keep the board's power-on defaults until HPS supplies its MRA settings.
    reg [7:0] dip_switches=8'h8e;
    always @(posedge clk_sys)
        if(ioctl_wr && ioctl_index==254 && ioctl_addr==0)
            dip_switches<=ioctl_data[7:0];
    reg [2:0] header_ok=0;
    reg seen_end=0,was_load=0,rom_loaded=0;
    wire gfx_busy,gfx_wait,gfx_initialized;
    always @(posedge clk_sys) begin
        was_load<=load;
        if(cold_reset) begin header_ok<=0;seen_end<=0;rom_loaded<=0;end
        else begin
            if(load && !was_load) begin header_ok<=0;seen_end<=0;rom_loaded<=0;end
            if(load_wr) begin
                if(board_load_addr==0) header_ok[0]<=board_load_data==16'h3641;
                if(board_load_addr==2) header_ok[1]<=board_load_data==16'h4e38;
                if(board_load_addr==4) header_ok[2]<=board_load_data[7:0]==1 && board_load_data[15:8]<=2;
                if(board_load_addr==25'h9fffe) seen_end<=1;
            end
            if(!load && !gfx_busy && gfx_initialized && &header_ok && seen_end)
                rom_loaded<=1;
        end
    end
    wire game_reset=cold_reset || reset_sync[2] || status[0] || buttons[1] || !rom_loaded;
    assign ioctl_wait=cold_reset || gfx_wait;
    wire [7:0] p0={joy0[6],1'b0,joy0[5],joy0[4],joy0[1],joy0[0],joy0[2],joy0[3]};
    wire [7:0] p1={joy1[6],1'b0,joy1[5],joy1[4],joy1[1],joy1[0],joy1[2],joy1[3]};
    wire ce_pix,hblank,vblank,hs,vs;
    wire [7:0] dac,profile;
    wire [23:0] game_rgb;
    wire signed [15:0] game_audio;
    wire raw_ce;
    wire [8:0] raw_x,raw_y,video_y;
    wire [7:0] video_x;
    wire [31:0] main_tx,unmapped,deadlines,overflows;
    wire [11:0] worst_line;
    wire ram_hs_access,ram_hs_write;
    wire [23:0] ram_hs_addr;
    wire [7:0] ram_hs_data;
`ifdef ALPHA_EMU_SIM
    // Explicit test borrower for the RAM protocol fixture only. Real-ROM boot
    // runs leave this disabled; it is absent from the production design.
    assign ram_hs_access=SIM_TEST_HS_ACCESS || hs_read || hs_write_intent;
    assign ram_hs_write=SIM_TEST_HS_ACCESS ? SIM_TEST_HS_WRITE : hs_write;
    assign ram_hs_addr=SIM_TEST_HS_ACCESS ? SIM_TEST_HS_ADDR : hs_addr;
    assign ram_hs_data=SIM_TEST_HS_ACCESS ? SIM_TEST_HS_DATA : hs_to_ram;
    assign SIM_HS_DATA=hs_from_ram;assign SIM_PAUSED=paused;
    assign SIM_HS_CONFIGURED=hs_configured;assign SIM_HS_REQUEST=ioctl_upload_req;
    assign SIM_DIRECT_VIDEO=direct_video;
    assign SIM_JOY0=joy0;assign SIM_USER_PAUSE=user_pause;
    assign SIM_HS_STATE=hi.state;assign SIM_HS_RESTORING=hi.restoring_dump;
    assign SIM_HS_EXTRACTING=hi.extracting_dump;
`else
    assign ram_hs_access=hs_read || hs_write_intent;assign ram_hs_write=hs_write;
    assign ram_hs_addr=hs_addr;assign ram_hs_data=hs_to_ram;
`endif
    alpha68kn_system system (
        .clk(clk_sys),.cold_reset(cold_reset),.reset(game_reset),.downloading(load),
        .load_wr(load_wr),.load_addr(board_load_addr),.load_data(board_load_data),
        .pause_game(pause_game),.paused(paused),.rotate180(status[7]),
        .hs_access(ram_hs_access),.hs_addr(ram_hs_addr),
        .hs_write(ram_hs_write),.hs_data_in(ram_hs_data),.hs_data_out(hs_from_ram),
        .controls({p1,p0}),.dips(dip_switches),.coins_n({!joy1[7],!joy0[7]}),
        .profile(profile),.dac(dac),.load_wait(gfx_wait),.load_busy(gfx_busy),.initialized(gfx_initialized),
        .raw_ce(raw_ce),.raw_x(raw_x),.raw_y(raw_y),.raw_hblank(),.raw_vblank(),.raw_hs(),.raw_vs(),
        .video_ce(ce_pix),.video_rgb(game_rgb),.video_x(video_x),.video_y(video_y),
        .video_hblank(hblank),.video_vblank(vblank),.video_hs(hs),.video_vs(vs),
        .audio_sample(game_audio),.audio_sample_ce(),.audio_clipped_samples(),
        .ym_writes(),.ay1_writes(),.ay2_writes(),
        .sound_io_wr(),.sound_io_addr(),.sound_io_data(),
        .sound_io_rd(),.sound_io_read_addr(),.sound_io_read_data(),.sound_dac_wr(),
        .debug_main_addr(),.debug_sound_addr(),.debug_main_as_n(),.debug_main_attrs(),
        .debug_sound_attrs(),.debug_sound_din(),.debug_sound_dout(),
        .debug_main_din(),.debug_main_dout(),.main_transactions(main_tx),.sound_transactions(),
        .work_writes(),.strip_writes(),.mcu_transactions(),.irq1_acks(),.irq2_acks(),
        .unmapped_accesses(unmapped),.debug_word_addr(12'd0),.debug_work_data(),.debug_strip_data(),
        .debug_rom_kind(4'd0),.debug_rom_addr(16'd0),.debug_rom_data(),
        .worst_line_cycles(worst_line),.completed_lines(),.deadline_misses(deadlines),.row_overflows(overflows),
        .sdram_dq(SDRAM_DQ),
`ifdef VERILATOR
`ifdef ALPHA_EMU_SIM
        .sdram_din(SIM_SDRAM_DIN),
`else
        .sdram_din(),
`endif
`endif
        .sdram_a(SDRAM_A),.sdram_ba(SDRAM_BA),.sdram_dqml(SDRAM_DQML),.sdram_dqmh(SDRAM_DQMH),
        .sdram_nwe(SDRAM_nWE),.sdram_ncas(SDRAM_nCAS),.sdram_nras(SDRAM_nRAS),
        .sdram_ncs(SDRAM_nCS),.sdram_cke(SDRAM_CKE)
    );
    hiscore #(.HS_ADDRESSWIDTH(24),.HS_SCOREWIDTH(8),.CFG_ADDRESSWIDTH(2)) hi (
        .clk(clk_sys),.reset(game_reset),.paused(paused),.autosave(!status[28]),
        .ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr[24:0]),.ioctl_index(ioctl_index[7:0]),.OSD_STATUS(user_pause && !game_reset),
        .data_from_hps(ioctl_data),.data_from_ram(hs_from_ram),
        .ram_address(hs_addr),.data_to_hps(ioctl_din),.data_to_ram(hs_to_ram),
        .ram_write(hs_write),.ram_intent_read(hs_read),.ram_intent_write(hs_write_intent),
        .pause_cpu(hs_pause),.configured(hs_configured)
    );
    reg credits_key_last=0,credits_mouse_last=0;
    always @(posedge clk_sys) begin
        credits_key_last<=credits_key[10];
        credits_mouse_last<=credits_mouse[24];
    end
    wire credits_dismiss=|(joy0|joy1|joy2|joy3|joy4|joy5) || |buttons ||
        (credits_key[10]^credits_key_last) || (credits_mouse[24]^credits_mouse_last) || osd_sync[1];
    wire [23:0] credits_rgb;
    wire credits_hs,credits_vs,credits_hb,credits_vb,credits_de,credits_active;
    credits_overlay #(.WIDTH(256),.HEIGHT(224),.SCALE_LOG2(0),.SCROLL_FRAMES(4),.ROTATE_CCW(1),.OPEN_AT_TOP(1)) credits (
        .clk_video(clk_sys),.reset(game_reset),.ce_pixel(ce_pix),
        .menu_trigger(status[120]),.dismiss(credits_dismiss),
        .r_in(rom_loaded ? game_rgb[23:16] : 8'd0),
        .g_in(rom_loaded ? game_rgb[15:8] : 8'd0),
        .b_in(rom_loaded ? game_rgb[7:0] : 8'd0),
        .hs_in(hs),.vs_in(vs),.hblank_in(hblank || !rom_loaded),.vblank_in(vblank || !rom_loaded),
        .r_out(credits_rgb[23:16]),.g_out(credits_rgb[15:8]),.b_out(credits_rgb[7:0]),
        .hs_out(credits_hs),.vs_out(credits_vs),.hblank_out(credits_hb),.vblank_out(credits_vb),
        .de_out(credits_de),.active(credits_active)
    );
    wire mixer_ce,mixer_de,mixer_hs,mixer_vs;
    wire [23:0] mixer_rgb;
    arcade_video #(.WIDTH(256),.DW(24)) video (
        .clk_video(clk_sys),.ce_pix(ce_pix),.RGB_in(credits_rgb),
        .HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(mixer_ce),.VGA_R(mixer_rgb[23:16]),.VGA_G(mixer_rgb[15:8]),.VGA_B(mixer_rgb[7:0]),
        .VGA_HS(mixer_hs),.VGA_VS(mixer_vs),.VGA_DE(mixer_de),.VGA_SL(VGA_SL),
        .fx(status[4:2]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus)
    );
    wire video_rotated;
    // CRT processing uses native pixels only. Scandoubled/HQ2x streams bypass
    // it. Direct video keeps native line cadence: V-size retiming is bypassed.
    wire crt_active=status[11] && status[4:2]==0 && !forced_scandoubler;
    wire [23:0] crt_rgb;
    wire crt_ce,crt_hs,crt_vs,crt_de;
    alpha68kn_crt crt (
        .clk(clk_sys),.ce_in(mixer_ce),.rgb_in(mixer_rgb),.hs_in(mixer_hs),.vs_in(mixer_vs),
        .de_in(mixer_de),.vb_in(credits_vb),.active(crt_active),.direct_video(direct_video),
        .hsize(status[14:12]),.hpos(status[19:15]),.vpos(status[24:20]),.vsize(status[27:25]),
        .ce_out(crt_ce),.rgb_out(crt_rgb),.hs_out(crt_hs),.vs_out(crt_vs),.de_out(crt_de)
    );
    assign CE_PIXEL=crt_ce;
    assign VGA_R=crt_rgb[23:16];assign VGA_G=crt_rgb[15:8];assign VGA_B=crt_rgb[7:0];
    assign VGA_HS=crt_hs;assign VGA_VS=crt_vs;
    wire [12:0] scaled_arx,scaled_ary;
    assign VIDEO_ARX=video_rotated ? scaled_ary : scaled_arx;
    assign VIDEO_ARY=video_rotated ? scaled_arx : scaled_ary;
    video_freak scale (
        .CLK_VIDEO(clk_sys),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),
        .HDMI_WIDTH(video_rotated ? HDMI_HEIGHT : HDMI_WIDTH),
        .HDMI_HEIGHT(video_rotated ? HDMI_WIDTH : HDMI_HEIGHT),
        .VGA_DE(VGA_DE),.VGA_DE_IN(crt_de),.VIDEO_ARX(scaled_arx),.VIDEO_ARY(scaled_ary),
        .ARX(status[5] ? 12'd0 : 12'd4),
        .ARY(status[5] ? 12'd0 : 12'd3),
        .CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(direct_video ? 3'd0 : status[10:8])
    );
    assign VGA_F1=0; assign VGA_SCALER=0; assign VGA_DISABLE=0;
`ifdef ALPHA_EMU_SIM
    assign SIM_COLD_RESET=cold_reset;assign SIM_GAME_RESET=game_reset;
    assign SIM_ROM_LOADED=rom_loaded;assign SIM_IOCTL_WAIT=ioctl_wait;
    assign SIM_LOAD_WR=load_wr;assign SIM_LOAD_ADDR=board_load_addr;assign SIM_LOAD_DATA=board_load_data;
    assign SIM_CONTROLS={p1,p0};assign SIM_COINS={!joy1[7],!joy0[7]};assign SIM_PROFILE=profile;
    assign SIM_DIPS=dip_switches;
    assign SIM_RAW_CE=raw_ce;assign SIM_RAW_X=raw_x;assign SIM_RAW_Y=raw_y;
    assign SIM_VIDEO_CE=ce_pix;assign SIM_VIDEO_HB=hblank;assign SIM_VIDEO_VB=vblank;
    assign SIM_VIDEO_X=video_x;assign SIM_VIDEO_Y=video_y;assign SIM_VIDEO_RGB=game_rgb;
    assign SIM_MAIN_TX=main_tx;assign SIM_UNMAPPED=unmapped;
    assign SIM_DEADLINES=deadlines;assign SIM_OVERFLOWS=overflows;assign SIM_WORST_LINE=worst_line;
`endif
    assign HDMI_FREEZE=0; assign HDMI_BLACKOUT=0; assign HDMI_BOB_DEINT=0;
    assign AUDIO_L=game_reset ? 16'd0 : game_audio;
    assign AUDIO_R=AUDIO_L; assign AUDIO_S=1; assign AUDIO_MIX=0;
    assign LED_USER=load; assign LED_POWER=0; assign LED_DISK=0; assign BUTTONS=0;
    assign ADC_BUS=4'bzzzz;
    assign SD_SCK=0; assign SD_MOSI=0; assign SD_CS=1;
    assign UART_RTS=0; assign UART_TXD=0; assign UART_DTR=0; assign USER_OUT=7'h7f;
`ifdef MISTER_FB
    // MAME ROT90 is clockwise. Board flip is already in the renderer.
    screen_rotate rotation (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
        .rotate_ccw(status[6]),.no_rotate(status[1] || direct_video),.flip(1'b0),.video_rotated(video_rotated),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
        .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
        .DDRAM_ADDR(DDRAM_ADDR),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD)
    );
    assign FB_FORCE_BLANK=0;
`ifdef MISTER_FB_PALETTE
    assign FB_PAL_CLK=0; assign FB_PAL_ADDR=0; assign FB_PAL_DOUT=0; assign FB_PAL_WR=0;
`endif
`else
    assign video_rotated=0;
    assign DDRAM_CLK=clk_sys; assign DDRAM_BURSTCNT=0; assign DDRAM_ADDR=0;
    assign DDRAM_RD=0; assign DDRAM_DIN=0; assign DDRAM_BE=0; assign DDRAM_WE=0;
`endif
`ifdef MISTER_DUAL_SDRAM
    assign SDRAM2_CLK=1'bz; assign SDRAM2_A=13'bz; assign SDRAM2_BA=2'bz;
    assign SDRAM2_DQ=16'bz; assign SDRAM2_nCS=1'bz; assign SDRAM2_nCAS=1'bz;
    assign SDRAM2_nRAS=1'bz; assign SDRAM2_nWE=1'bz;
`endif
endmodule
