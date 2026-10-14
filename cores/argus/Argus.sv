// Argus / Valtric / Butasan family MiSTer integration. sys/ stays pristine.
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='Z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_F1=0;
    assign VGA_SCALER=0;
    assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0;
    assign HDMI_BLACKOUT=0;
    assign HDMI_BOB_DEINT=0;
    assign LED_DISK=0;
    assign LED_POWER=0;
    assign BUTTONS=0;
    assign AUDIO_S=1;
    assign AUDIO_MIX=0;
    `include "build_id.v"
    localparam CONF_STR = {
        "Argus;;",
        "-;",
        "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "H0O[6:5],Rotation,Game default,Off,90 CW,90 CCW;",
        "O[7],Rotate 180,Off,On;",
        "O[11:9],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
        "H0O[13:12],Scaling,Normal,V integer,HV integer;",
        "H1O[14],Autosave,On,Off;",
        "-;",
        "DIP;",
        "-;",
        "H2T[15],Service;",
        "H4T[16],Test mode;",
        "P2,CRT Adjust;",
        "P2O[29],CRT Adjust,Off,On;",
        "H3P2O[32:30],H size,0,1,2,3,-4,-3,-2,-1;",
        "H3P2O[39:35],H position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H3P2O[44:40],V position,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H3P2O[50:45],V size,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H3P2O[51],Tube mode,Off,On;",
        "-;",
        "R[120],Credits;",
        "R[0],Reset;",
        // MiSTer Main takes the function names and keyboard defaults from each
        // MRA's <buttons> override. J1 retains keyboard joystick mode.
        "J1;",
        "v,1;",
        "V,v",`BUILD_DATE
    };
    wire clk_sys, clk_sdram, pll_locked;
    pll game_pll (.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),
                  .outclk_1(clk_sdram),.locked(pll_locked));
    assign SDRAM_CLK=clk_sdram;
    wire storage_reset=RESET || !pll_locked;
    wire [127:0] status;
    wire [1:0] buttons;
    wire [31:0] joystick_0,joystick_1;
    wire forced_scandoubler,direct_video;
    wire [21:0] gamma_bus;
    wire [15:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [7:0] ioctl_dout;
    wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd;
    wire rom_wait,hs_wait,hs_upload_req;
    wire [7:0] hs_data_to_hps;
    wire hs_configured,hs_initialized,hs_dirty,hs_error;
    wire video_rotated,crt_active,hdmi_menu_hidden,crt_menu_hidden;
    logic [1:0] game_id=0;
    logic last_rom_download;
    wire rom_download=ioctl_download && ioctl_index==16'd0;
    wire rom_load_start=rom_download && !last_rom_download;
    always_ff @(posedge clk_sys) begin
        if(storage_reset) begin game_id<=0;last_rom_download<=0;end
        else begin
            last_rom_download<=rom_download;
            if(ioctl_download && ioctl_wr && ioctl_index==16'd1 && ioctl_addr==0)
                game_id<=ioctl_dout<3 ? ioctl_dout[1:0] : 2'd3;
        end
    end
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps (
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .buttons(buttons),.status(status),.status_in(128'd0),.status_set(1'b0),
        .status_menumask({11'd0,game_id!=2,crt_menu_hidden,game_id==0,!hs_configured,hdmi_menu_hidden}),
        .gamma_bus(gamma_bus),.forced_scandoubler(forced_scandoubler),
        .direct_video(direct_video),.video_rotated(video_rotated),.new_vmode(1'b0),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
        .ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_din(hs_data_to_hps),
        .ioctl_upload_req(hs_upload_req),.ioctl_upload_index(8'd4),
        .ioctl_wait(rom_wait || hs_wait)
    );
    wire [7:0] system_in,p1_in,p2_in,dip1,dip2;
    wire pause_button,test_entry_req;
    wire normal_game_reset=status[0] || buttons[1];
    wire test_hold,test_reset,test_mode;
    wire game_reset=normal_game_reset || test_reset;
    wire feature_session_reset=storage_reset || rom_load_start;
    wire frame_start;
    argus_test_entry test_control (
        .clk_sys(clk_sys),.session_reset(feature_session_reset),.normal_reset(normal_game_reset),
        .test_request(test_entry_req),.game_id(game_id),
        .input_read(debug_input_read),.input_addr(debug_input_addr),.input_data(debug_input_data),
        .test_hold(test_hold),.test_reset(test_reset),.test_mode(test_mode)
    );
    wire dip_transfer=ioctl_index==16'd254;
    argus_controls controls (
        .clk_sys(clk_sys),.reset(storage_reset),.game_id(game_id),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .service_button(status[15]),.test_button(status[16]),.test_hold(test_hold),
        .ioctl_download(ioctl_download && dip_transfer),.ioctl_wr(ioctl_wr && dip_transfer),
        .ioctl_index(8'd254),.ioctl_dout(ioctl_dout),.ioctl_addr(ioctl_addr[24:0]),
        .system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.dip1(dip1),.dip2(dip2),
        .pause_button(pause_button),.test_entry_req(test_entry_req)
    );
    logic pause_toggle,previous_pause_button;
    always_ff @(posedge clk_sys) begin
        if(feature_session_reset) begin pause_toggle<=0;previous_pause_button<=0;end
        else begin
            previous_pause_button<=pause_button;
            if(pause_button && !previous_pause_button) pause_toggle<=~pause_toggle;
            if(test_entry_req) pause_toggle<=1'b0;
        end
    end
    wire pause_game,hs_pause,hs_pause_grant,cpu_ram_quiescent,ram_busy;
    wire hs_ram_req,hs_ram_we,hs_ram_ack;
    wire cpu_ram_write;
    wire [15:0] cpu_ram_addr;
    wire [7:0] cpu_ram_wdata;
    wire [15:0] hs_ram_addr;
    wire [7:0] hs_ram_wdata,hs_ram_rdata;
    argus_pause pause_control (
        .clk_sys(clk_sys),.reset(feature_session_reset),.user_pause(pause_toggle),
        .osd_open(OSD_STATUS),.hiscore_pause(hs_pause),.frame_start(frame_start),
        .pause_game(pause_game),.ram_grant(hs_pause_grant)
    );
    // Full-width index check precedes the adapter's local 8-bit protocol.
    wire persistence_transfer=ioctl_index==16'd3 || ioctl_index==16'd4;
    wire [7:0] persistence_index=persistence_transfer ? ioctl_index[7:0] : 8'hff;
    argus_hiscore #(.HPS_UPLOAD_PREFETCH(1'b1)) persistence (
        .clk_sys(clk_sys),.reset(storage_reset),.session_reset(rom_load_start),
        .game_reset(game_reset || test_entry_req),.game_id(game_id),.frame_start(frame_start && !test_mode),
        .cpu_ram_write(cpu_ram_write),.cpu_ram_addr(cpu_ram_addr),.cpu_ram_wdata(cpu_ram_wdata),
        .ram_grant(hs_pause_grant && cpu_ram_quiescent),.osd_open(OSD_STATUS),.autosave(!status[14]),
        .ioctl_download(ioctl_download && persistence_transfer),
        .ioctl_upload(ioctl_upload && persistence_transfer),
        .ioctl_wr(ioctl_wr && persistence_transfer),.ioctl_rd(ioctl_rd && persistence_transfer),
        .ioctl_addr(ioctl_addr[24:0]),.ioctl_index(persistence_index),.data_from_hps(ioctl_dout),
        .data_to_hps(hs_data_to_hps),.ioctl_upload_req(hs_upload_req),.ioctl_wait(hs_wait),
        .configured(hs_configured),.initialized(hs_initialized),.dirty(hs_dirty),.protocol_error(hs_error),
        .pause_cpu(hs_pause),.ram_req(hs_ram_req),.ram_we(hs_ram_we),.ram_addr(hs_ram_addr),
        .ram_wdata(hs_ram_wdata),.ram_ack(hs_ram_ack),.ram_rdata(hs_ram_rdata)
    );
    wire [1:0] rotation=status[6:5]==0 ? (game_id==2 ? 2'd0 : 2'd2) :
                         status[6:5]==1 ? 2'd0 : status[6:5]==2 ? 2'd1 : 2'd2;
    wire rotate_ccw,no_rotate,presentation_flip,user_flip_180;
    wire [11:0] original_arx,original_ary;
    wire [2:0] freak_scale;
    argus_video_options video_options (
        .rotation(rotation),.scale(status[13:12]),.native_flip_180(status[7]),
        .direct_video(direct_video),.forced_scandoubler(forced_scandoubler),.effects(status[11:9]),
        .crt_enable(status[29]),.rotate_ccw(rotate_ccw),.no_rotate(no_rotate),
        .presentation_flip(presentation_flip),.user_flip_180(user_flip_180),
        .arx(original_arx),.ary(original_ary),.freak_scale(freak_scale),
        .crt_active(crt_active),.hdmi_menu_hidden(hdmi_menu_hidden),.crt_menu_hidden(crt_menu_hidden)
    );
    wire native_ce,native_active,native_hblank,native_vblank,native_hs,native_vs;
    wire line_start,pixel_valid,load_ready,bounds_error,deadline_miss;
    wire [9:0] hpos,vpos;
    wire [7:0] native_r,native_g,native_b;
    wire [15:0] debug_pc;
    wire [2:0] debug_bank;
    wire debug_irq_n,debug_irq_ack,debug_input_read,debug_sound_cmd_we;
    wire [7:0] debug_irq_vector,debug_input_data,debug_sound_cmd;
    wire [15:0] debug_input_addr;
    argus_machine machine (
        .clk_sys(clk_sys),.storage_reset(storage_reset),.game_reset(game_reset),
        .pause_game(pause_game),.game_id(game_id),.timing_profile(2'd0),
        .system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.dip1(dip1),.dip2(dip2),
        .user_flip_180(user_flip_180),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr[24:0]),.ioctl_dout(ioctl_dout),
        .ioctl_wait(rom_wait),.load_ready(load_ready),.bounds_error(bounds_error),
        .ram_req(hs_ram_req),.ram_we(hs_ram_we),.ram_grant(hs_pause_grant && cpu_ram_quiescent),
        .ram_addr(hs_ram_addr),.ram_wdata(hs_ram_wdata),.ram_ack(hs_ram_ack),.ram_rdata(hs_ram_rdata),
        .ce_pixel(native_ce),.pixel_valid(pixel_valid),.active(native_active),
        .hblank(native_hblank),.vblank(native_vblank),.hs(native_hs),.vs(native_vs),
        .line_start(line_start),.frame_start(frame_start),.hpos(hpos),.vpos(vpos),
        .r(native_r),.g(native_g),.b(native_b),.audio_l(AUDIO_L),.audio_r(AUDIO_R),.sample_ce(),
        .deadline_miss(deadline_miss),.debug_pc(debug_pc),.debug_bank(debug_bank),
        .debug_irq_n(debug_irq_n),.debug_irq_ack(debug_irq_ack),.debug_irq_vector(debug_irq_vector),
        .debug_input_read(debug_input_read),.debug_input_addr(debug_input_addr),.debug_input_data(debug_input_data),
        .debug_sound_cmd_we(debug_sound_cmd_we),.debug_sound_cmd(debug_sound_cmd),
        .debug_cpu_ram_write(cpu_ram_write),.debug_cpu_ram_addr(cpu_ram_addr),
        .debug_cpu_ram_wdata(cpu_ram_wdata),
        .debug_bus_quiescent(cpu_ram_quiescent),.debug_ram_busy(ram_busy),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_CKE(SDRAM_CKE)
    );
    assign LED_USER=rom_download || hs_dirty || bounds_error || deadline_miss;
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hblank,crt_vblank,ce_crt;
    wire signed [6:0] vsize_decoded=status[50:45]<=21 ? $signed({1'b0,status[50:45]}) :
                                  status[50:45]<=42 ? $signed({1'b0,status[50:45]})-7'sd43 : 7'sd0;
    wire signed [5:0] vsize=vsize_decoded[5:0];
    argus_crt_video #(.H_TOTAL(400),.V_TOTAL(250),.PIXEL_DIV(10)) crt (
        .clk_sys(clk_sys),.reset(storage_reset),.frame_start(frame_start),
        // Whole system-clock periods keep each adjusted pixel equally spaced.
        .ce_pixel(native_ce),.enable(crt_active),.hsize($signed({status[32:30],2'b00})),
        .hposition({{4{status[39]}},status[39:35]}),.vposition({status[44],status[44:40]}),
        .vsize(vsize),.tube_mode(status[51]),
        .r_in(pixel_valid?native_r:8'd0),.g_in(pixel_valid?native_g:8'd0),.b_in(pixel_valid?native_b:8'd0),
        .hs_in(native_hs),.vs_in(native_vs),.hblank_in(native_hblank),.vblank_in(native_vblank),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),.hs_out(crt_hs),.vs_out(crt_vs),
        .hblank_out(crt_hblank),.vblank_out(crt_vblank),.ce_out(ce_crt)
    );
    // MeatCore credits overlay: native raster, before the mixer and rotation.
    // rotation is the downstream transform: 0 normal, 1 CW, 2 half turn, 3 CCW.
    wire [7:0] credits_r,credits_g,credits_b;
    wire credits_hs,credits_vs,credits_hb,credits_vb,credits_active;
    wire credits_dismiss=|joystick_0 || |joystick_1 || |buttons || OSD_STATUS;
    wire [1:0] credits_rotation=no_rotate ? (presentation_flip ? 2'd2 : 2'd0) :
                                (rotate_ccw ? 2'd3 : 2'd1);
    credits_overlay #(.WIDTH(256),.HEIGHT(224)) credits (
        .clk_video(clk_sys),.reset(storage_reset),.ce_pixel(ce_crt),
        .menu_trigger(status[120]),.dismiss(credits_dismiss),.rotation(credits_rotation),
        .r_in(crt_r),.g_in(crt_g),.b_in(crt_b),.hs_in(crt_hs),.vs_in(crt_vs),
        .hblank_in(crt_hblank),.vblank_in(crt_vblank),
        .r_out(credits_r),.g_out(credits_g),.b_out(credits_b),.hs_out(credits_hs),.vs_out(credits_vs),
        .hblank_out(credits_hb),.vblank_out(credits_vb),.de_out(),.active(credits_active)
    );
    wire native_de;
    // Four OSD choices: none or the three original scanline strengths.
    wire [2:0] fx_nohq = status[11:9] == 0 ? 3'd0 :
                          status[11:9] < 4 ? status[11:9] + 3'd1 : 3'd0;
    argus_arcade_video #(.WIDTH(256),.DW(24)) native_video (
        .clk_video(clk_sys),.ce_pix(ce_crt),.RGB_in({credits_r,credits_g,credits_b}),
        .HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),
        .VGA_DE(native_de),.VGA_SL(VGA_SL),.fx(fx_nohq),
        .forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus)
    );
`ifdef MISTER_FB
    wire rotate_ddr_clk,rotate_ddr_busy,rotate_ddr_we,rotate_ddr_rd;
    wire [7:0] rotate_ddr_burst,rotate_ddr_be;
    wire [28:0] rotate_ddr_addr;
    wire [63:0] rotate_ddr_data;
    wire rotation_overflow,rotation_fault_blank;
    screen_rotate rotate (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(native_de),
        .rotate_ccw(rotate_ccw),.no_rotate(no_rotate),.flip(presentation_flip),
        .video_rotated(video_rotated),.FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),
        .FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),
        .FB_VBL(FB_VBL),.FB_LL(FB_LL),.DDRAM_CLK(rotate_ddr_clk),.DDRAM_BUSY(rotate_ddr_busy),
        .DDRAM_BURSTCNT(rotate_ddr_burst),.DDRAM_ADDR(rotate_ddr_addr),.DDRAM_DIN(rotate_ddr_data),
        .DDRAM_BE(rotate_ddr_be),.DDRAM_WE(rotate_ddr_we),.DDRAM_RD(rotate_ddr_rd)
    );
    assign DDRAM_CLK=rotate_ddr_clk;
    argus_rotate_ddr_queue rotation_queue (
        .clk(rotate_ddr_clk),.reset(feature_session_reset),
        .src_burstcnt(rotate_ddr_burst),.src_addr(rotate_ddr_addr),.src_din(rotate_ddr_data),
        .src_be(rotate_ddr_be),.src_we(rotate_ddr_we),.src_rd(rotate_ddr_rd),
        .src_busy(rotate_ddr_busy),.src_accepted(),.dst_busy(DDRAM_BUSY),
        .dst_burstcnt(DDRAM_BURSTCNT),.dst_addr(DDRAM_ADDR),.dst_din(DDRAM_DIN),
        .dst_be(DDRAM_BE),.dst_we(DDRAM_WE),.dst_rd(DDRAM_RD),
        .overflow(rotation_overflow),.fault_blank(rotation_fault_blank),.used()
    );
    assign FB_FORCE_BLANK=rotation_fault_blank;
`else
    assign video_rotated=0;
    assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_RD,DDRAM_WE}='0;
`endif
    wire [1:0] aspect=status[122:121];
    wire [11:0] arx=aspect==0 ? original_arx : aspect==1 ? 12'd0 : {10'd0,aspect}-12'd1;
    wire [11:0] ary=aspect==0 ? original_ary : 12'd0;
    wire [12:0] normal_arx,normal_ary;
    video_freak sizing (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),
        .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.VGA_DE_IN(native_de),.VGA_DE(VGA_DE),
        .VIDEO_ARX(normal_arx),.VIDEO_ARY(normal_ary),.ARX(arx),.ARY(ary),
        .CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(3'd0)
    );
    argus_oriented_scale oriented_sizing (
        .CLK_VIDEO(CLK_VIDEO),.RESET(storage_reset),.CE_PIXEL(CE_PIXEL),
        .VGA_VS(VGA_VS),.VGA_DE(native_de),.ROTATED(!no_rotate),
        .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.SCALE(freak_scale),
        .ARX(normal_arx[11:0]),.ARY(normal_ary[11:0]),
        .VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY)
    );
endmodule

`include "rtl/features/argus_test_entry.sv"
