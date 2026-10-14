// SPDX-License-Identifier: GPL-3.0-or-later
// Target platform wiring. Shared board/video/audio modules also drive simulation.
assign ADC_BUS='z;
assign USER_OUT='1;
assign {UART_RTS,UART_TXD,UART_DTR}=0;
assign {SD_SCK,SD_MOSI,SD_CS}='z;
assign LED_POWER=0;
assign LED_DISK=0;
assign BUTTONS=0;
assign VGA_F1=0;
assign VGA_SCALER=0;
assign VGA_DISABLE=0;
assign HDMI_FREEZE=0;
assign HDMI_BLACKOUT=0;
assign HDMI_BOB_DEINT=0;
assign AUDIO_S=1;
assign AUDIO_MIX=0;
`ifdef MISTER_FB
assign FB_FORCE_BLANK=0;
`endif
`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_CLK,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}=5'b01111;
assign {SDRAM2_A,SDRAM2_BA}=0;
assign SDRAM2_DQ='z;
`endif
`ifdef MISTER_FB_PALETTE
assign {FB_PAL_CLK,FB_PAL_ADDR,FB_PAL_DOUT,FB_PAL_WR}=0;
`endif

`include "build_id.v"
localparam CONF_STR={
    "ZeroTeam;-;P1,Video;",
    "H0P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "H0P1O[7:5],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
    "H0P1O[2:1],Rotate 90,Off,Counter-clockwise,Clockwise;",
    "P1O[3],Rotate 180,Off,On;",
    "H0P1O[79],CRT Adjust,Off,On;",
    "H1P1O[66:62],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1P1O[104:98],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1P1O[60:56],CRT V-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,-2,-1;",
    "O[30],Swap players 1 and 2,Off,On;",
    "O[31],CPU Speed,Original (16 MHz),Turbo (19.2 MHz);",
    "R[120],Credits;",
    "DIP;T[0],Reset;R[0],Reset and close OSD;",
    "J1,Attack,Jump,-,-,-,-,Start,Coin,Pause,Service Credit,Service Menu;",
    "jn,A,B,,,,,Start,R,L,Select,Y;V,v",`BUILD_DATE
};
 wire clk_sys,pll_locked;
 pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.locked(pll_locked));
wire [127:0] status;
wire [1:0] buttons;
wire forced_scandoubler,direct_video;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire [31:0] pad0,pad1,pad2,pad3;
wire [31:0] pad4,pad5;
wire [24:0] ps2_mouse;
wire [15:0] key0,key1,key2,key3;
wire [15:0] joy0=pad0[15:0]|key0,joy1=pad1[15:0]|key1;
wire [15:0] joy2=pad2[15:0]|key2,joy3=pad3[15:0]|key3;
wire [15:0] joy_all=joy0|joy1|joy2|joy3;
wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_wait,ioctl_upload_req;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout,ioctl_din;
wire crt_on=status[79] && !direct_video && !forced_scandoubler;
hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps_io (
    .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
    .status(status),.buttons(buttons),.ps2_key(ps2_key),
    .status_menumask({14'd0,!crt_on,direct_video}),
    .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),
    .joystick_0(pad0),.joystick_1(pad1),.joystick_2(pad2),.joystick_3(pad3),
    .joystick_4(pad4),.joystick_5(pad5),.ps2_mouse(ps2_mouse),
    .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
    .ioctl_upload_req(ioctl_upload_req),.ioctl_upload_index(8'd4),
    .ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),.ioctl_wait(ioctl_wait)
);
wire rom_download=ioctl_download && ioctl_index==0;
wire initialization_download=ioctl_download && (ioctl_index==0 || ioctl_index==3 || ioctl_index==4);
wire word_wr,download_wait,download_busy;
wire [26:0] word_address;
wire [15:0] word_data;
ZeroTeam_download loader (
    .clk(clk_sys),.reset(!pll_locked),.download(ioctl_download),.wr(ioctl_wr),
    .index(ioctl_index),.address(ioctl_addr),.data(ioctl_dout),
    .memory_wait(download_wait),.wait_hps(ioctl_wait),
    .word_wr(word_wr),.word_address(word_address),.word_data(word_data)
);
wire sdram_ready;
wire reset_cause=RESET || status[0] || buttons[1] || !pll_locked ||
    !sdram_ready || initialization_download || download_busy;
reg [21:0] reset_hold=22'h3fffff;
(* maxfan=32 *) reg reset=1;
always @(posedge clk_sys) begin
    if(reset_cause) reset_hold<=22'h3fffff;
    else if(reset_hold!=0) reset_hold<=reset_hold-22'd1;
    reset<=reset_hold!=0;
end
assign LED_USER=rom_download;
reg [7:0] dips[0:3];
initial begin dips[0]=8'hff;dips[1]=8'hff;dips[2]=8'hff;dips[3]=8'hff;end
always @(posedge clk_sys)
    if(ioctl_wr && ioctl_index==254 && ioctl_addr<4) dips[ioctl_addr[1:0]]<=ioctl_dout;
wire [15:0] dsw={dips[1],dips[0]},system_config={dips[3],dips[2]};
wire [7:0] p1,p2,p3,p4,coins;
wire [15:0] system_port;
ZeroTeam_keyboard keyboard(.clk(clk_sys),.reset(reset),.ps2_key(ps2_key),
    .joy0(key0),.joy1(key1),.joy2(key2),.joy3(key3));
ZeroTeam_inputs inputs(
    .joy0(status[30]?joy1:joy0),.joy1(status[30]?joy0:joy1),.joy2(joy2),.joy3(joy3),
    .system_config(system_config),.service_credit(joy_all[13]),.service_test(joy_all[14]),
    .p1(p1),.p2(p2),.p3(p3),.p4(p4),.coin(coins),.system_port(system_port)
);
reg pause_toggle=0,old_pause=0;
always @(posedge clk_sys) begin
    old_pause<=joy_all[12];
    if(reset) pause_toggle<=0;
    else if(joy_all[12] && !old_pause) pause_toggle<=!pause_toggle;
end
wire cpu_idle,cop_busy,hs_pause,hs_read,hs_write,hs_write_intent,hs_configured;
wire [16:0] hs_address;
wire [7:0] hs_data_in,hs_data_out;
wire pause_request=pause_toggle || OSD_STATUS || hs_pause;
wire cpu_park=pause_request && cpu_idle;
wire paused=cpu_park && !cop_busy;
hiscore #(.HS_ADDRESSWIDTH(17),.HS_SCOREWIDTH(7),.CFG_ADDRESSWIDTH(2),.RAM_READ_PIPELINED(1)) highscores (
    .clk(clk_sys),.reset(reset),.paused(paused),.autosave(1'b1),
    .ioctl_upload(ioctl_upload),.ioctl_upload_req(ioctl_upload_req),
    .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_addr(ioctl_addr[24:0]),
    .ioctl_index(ioctl_index[7:0]),.OSD_STATUS(OSD_STATUS && !reset),
    .data_from_hps(ioctl_dout),.data_to_hps(ioctl_din),
    .data_from_ram(hs_data_out),.ram_address(hs_address),.data_to_ram(hs_data_in),
    .ram_write(hs_write),.ram_intent_read(hs_read),.ram_intent_write(hs_write_intent),
    .pause_cpu(hs_pause),.configured(hs_configured)
);

wire [23:0] sd_addr[0:3];
wire [15:0] sd_data[0:3],sd_write_data;
wire [3:0] sd_req,sd_ack;
wire sd_write;
wire [1:0] sd_len0;
wire sd_beat0;
sdram memory (
 .clk(clk_sys),.init(!pll_locked),.prio_mode(2'b01),.ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),.SDRAM_BA(SDRAM_BA),.SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CLK(SDRAM_CLK),.SDRAM_CKE(SDRAM_CKE),
    .addr0(sd_addr[0]),.wrl0(sd_write),.wrh0(sd_write),.din0(sd_write_data),
    .dout0(sd_data[0]),.req0(sd_req[0]),.ack0(sd_ack[0]),
    .rd_len0(sd_len0),.beat0(sd_beat0),
    .addr1(sd_addr[1]),.wrl1(1'b0),.wrh1(1'b0),.din1(16'd0),
    .dout1(sd_data[1]),.req1(sd_req[1]),.ack1(sd_ack[1]),
    .addr2(sd_addr[2]),.wrl2(1'b0),.wrh2(1'b0),.din2(16'd0),
    .dout2(sd_data[2]),.req2(sd_req[2]),.ack2(sd_ack[2]),
    .addr3(sd_addr[3]),.wrl3(1'b0),.wrh3(1'b0),.din3(16'd0),
    .dout3(sd_data[3]),.req3(sd_req[3]),.ack3(sd_ack[3])
);
wire main_req,cop_req,main_valid,cop_valid,gfx_req,gfx_valid;
wire [23:0] main_address,cop_address,gfx_address;
wire [15:0] main_data,cop_data;
wire [31:0] gfx_data;
wire [2:0] gfx_kind;
wire sprite_rom_req,sprite_rom_valid,sprite_rom_half;
wire [23:0] sprite_rom_address;
wire [31:0] sprite_rom_data;
wire [17:0] oki_address;
wire [7:0] oki_data;
wire oki_valid;
ZeroTeam_rom_bridge roms (
    .clk(clk_sys),.reset(!pll_locked),.ready(sdram_ready),.download(rom_download),
    .word_wr(word_wr),.word_address(word_address),.word_data(word_data),
    .download_wait(download_wait),.download_busy(download_busy),.gfx_req(gfx_req),.gfx_address(gfx_address),
    .gfx_kind(gfx_kind),.gfx_data(gfx_data),.gfx_valid(gfx_valid),
    .spr_req(sprite_rom_req),.spr_address(sprite_rom_address),.spr_data(sprite_rom_data),
    .spr_valid(sprite_rom_valid),.spr_half(sprite_rom_half),
    .len0(sd_len0),.beat0(sd_beat0),
    .main_req(main_req),.main_address(main_address),.main_data(main_data),.main_valid(main_valid),
    .cop_req(cop_req),.cop_address(cop_address),.cop_data(cop_data),.cop_valid(cop_valid),
    .oki_address(oki_address),.oki_data(oki_data),.oki_valid(oki_valid),
    .addr0(sd_addr[0]),.addr1(sd_addr[1]),.addr2(sd_addr[2]),.addr3(sd_addr[3]),
    .din0(sd_write_data),.we0(sd_write),.req0(sd_req[0]),.req1(sd_req[1]),
    .req2(sd_req[2]),.req3(sd_req[3]),.ack0(sd_ack[0]),.ack1(sd_ack[1]),
    .ack2(sd_ack[2]),.ack3(sd_ack[3]),.dout0(sd_data[0]),.dout1(sd_data[1]),
    .dout2(sd_data[2]),.dout3(sd_data[3])
);
wire [10:0] bg_address,mg_address,fg_address,tx_address,spr_address,pal_address;
wire [15:0] bg_data,mg_data,fg_data,tx_data,spr_data,pal_data;
wire [15:0] bg_x,bg_y,mg_x,mg_y,fg_x,fg_y;
wire bg_enable,mg_enable,fg_enable,tx_enable,spr_enable,crtc_flip;
wire snd_cs,snd_wr,snd_rd;
wire [4:1] snd_address;
wire [15:0] snd_write_data,snd_read_data;
wire native_ce,native_hb,native_vb,native_hs,native_vs,native_de;
wire [7:0] game_r,game_g,game_b;
wire pixel_strobe,pixel_display;
ssbus_if ss_workram(),ss_txt(),ss_scroll(),ss_spr(),ss_cpu(),ss_bank();
ssbus_if ss_copa(),ss_copr(),ss_bg(),ss_fg(),ss_pal(),ss_crtc();
`define ZERO_IDLE_STATE(s) assign s.data=0;assign s.addr=0;assign s.select=0;assign s.write=0;assign s.read=0;assign s.query=0;
`ZERO_IDLE_STATE(ss_workram) `ZERO_IDLE_STATE(ss_txt) `ZERO_IDLE_STATE(ss_scroll)
`ZERO_IDLE_STATE(ss_spr) `ZERO_IDLE_STATE(ss_cpu) `ZERO_IDLE_STATE(ss_bank)
`ZERO_IDLE_STATE(ss_copa) `ZERO_IDLE_STATE(ss_copr) `ZERO_IDLE_STATE(ss_bg)
`ZERO_IDLE_STATE(ss_fg) `ZERO_IDLE_STATE(ss_pal) `ZERO_IDLE_STATE(ss_crtc)
`undef ZERO_IDLE_STATE
Raiden2_main_top #(.SS_IDX_SPR(7),.SS_IDX_CPU(8),.SS_IDX_BANK(3),
    .SS_IDX_COPA(11),.SS_IDX_COPR(15),.HS_ENABLED(1),.IRQ_HALF_CAPTURE(1)) board (
    .clk(clk_sys),.reset(reset),.board_dx(1'b0),.clk_sel(status[31] ? 3'd4 : 3'd0),
    .pause(cpu_park),.cpu_idle(cpu_idle),.cop_busy_out(cop_busy),
    .hs_access((hs_read || hs_write_intent) && paused && hs_pause),
    .hs_write(hs_write),.hs_address(hs_address),.hs_data_in(hs_data_in),.hs_data_out(hs_data_out),
    .p1_input(p1),.p2_input(p2),.p3_input(p3),.p4_input(p4),
    .dsw_input(dsw),.dsw2_input(16'hffff),.system_input(system_port),
    .main_rom_rdata(main_data),.main_rom_ready(main_valid),
    .main_rom_addr(main_address),.main_rom_req(main_req),
    .cop_rom_rdata(cop_data),.cop_rom_ready(cop_valid),
    .cop_rom_addr(cop_address),.cop_rom_req(cop_req),
    .vblank_in(native_vb),.ioctl_download(rom_download),
    .snd_cs(snd_cs),.snd_addr(snd_address),.snd_wr(snd_wr),.snd_rd(snd_rd),
    .snd_wdata(snd_write_data),.snd_rdata(snd_read_data),
    .text_vram_addr(tx_address),.text_vram_data(tx_data),
    .spr_vram_addr(spr_address),.spr_vram_data(spr_data),
    .bg_vram_addr(bg_address),.bg_vram_data(bg_data),
    .mg_vram_addr(mg_address),.mg_vram_data(mg_data),
    .fg_vram_addr(fg_address),.fg_vram_data(fg_data),
    .pal_vram_addr(pal_address),.pal_vram_data(pal_data),
    .crtc_layer_en_bg(bg_enable),.crtc_layer_en_mg(mg_enable),
    .crtc_layer_en_fg(fg_enable),.crtc_layer_en_text(tx_enable),.crtc_layer_en_spr(spr_enable),
    .crtc_flip_screen(crtc_flip),.crtc_scroll_bg_x(bg_x),.crtc_scroll_bg_y(bg_y),
    .crtc_scroll_mg_x(mg_x),.crtc_scroll_mg_y(mg_y),
    .crtc_scroll_fg_x(fg_x),.crtc_scroll_fg_y(fg_y),.main_shared_rdata(16'hffff),
    .ss_bg(ss_bg),.ss_fg(ss_fg),.ss_pal(ss_pal),.ss_crtc(ss_crtc),
    .ss_workram(ss_workram),.ss_txt(ss_txt),.ss_scroll(ss_scroll),.ss_spr(ss_spr),
    .ss_cpu(ss_cpu),.ss_bank(ss_bank),.ss_copa(ss_copa),.ss_copr(ss_copr),.ss_cpu_reload(1'b0)
);
ZeroTeam_audio #(.ROM_BASE(27'h560000)) audio (
    .clk(clk_sys),.reset(reset),.pause(paused),
    .ioctl_download(rom_download),.ioctl_wr(word_wr),.ioctl_addr(word_address),.ioctl_dout(word_data),
    .snd_cs(snd_cs),.snd_addr(snd_address[3:1]),.snd_wr(snd_wr),.snd_rd(snd_rd),
    .snd_wdata(snd_write_data),.snd_rdata(snd_read_data),.coin_input(coins),
    .oki_rom_addr(oki_address),.oki_rom_data(oki_data),.oki_rom_ok(oki_valid),
    .out_l(AUDIO_L),.out_r(AUDIO_R)
);
ZeroTeam_video #(.SEPARATE_TIMING_RESET(1)) video (
    .clk(clk_sys),.reset(reset),.timing_reset(!pll_locked),
    .layer_enable({spr_enable,tx_enable,fg_enable,mg_enable,bg_enable}),
    .flip_screen(crtc_flip ^ status[3]),
    .bg_x(bg_x),.bg_y(bg_y),.mg_x(mg_x),.mg_y(mg_y),.fg_x(fg_x),.fg_y(fg_y),
    .tx_x(16'd0),.tx_y(16'd0),.bg_address(bg_address),.mg_address(mg_address),
    .fg_address(fg_address),.tx_address(tx_address),.spr_address(spr_address),.pal_address(pal_address),
    .bg_data(bg_data),.mg_data(mg_data),.fg_data(fg_data),.tx_data(tx_data),.spr_data(spr_data),.pal_data(pal_data),
    .rom_request(gfx_req),.rom_address(gfx_address),.rom_kind(gfx_kind),.rom_data(gfx_data),.rom_valid(gfx_valid),
    .sprite_rom_request(sprite_rom_req),.sprite_rom_address(sprite_rom_address),
    .sprite_rom_data(sprite_rom_data),.sprite_rom_valid(sprite_rom_valid),.sprite_rom_half(sprite_rom_half),
    .ce_pixel(native_ce),.display_enable(native_de),.hblank(native_hb),.vblank(native_vb),
    .hsync(native_hs),.vsync(native_vs),.r(game_r),.g(game_g),.b(game_b),
    .pixel_strobe(pixel_strobe),.pixel_display(pixel_display)
);
// RGB completes late in its native pixel period. Sample the completed RGB and
// its DE together, with sync/vertical blank delayed by the same whole pixel.
reg sync_h=0,sync_v=0,sync_vb=1,sync_hb=1;
reg [7:0] px_r=0,px_g=0,px_b=0;
reg px_hs=0,px_vs=0,px_hb=1,px_vb=1,px_ce=0;
always @(posedge clk_sys) begin
    px_ce<=native_ce;
    if(native_ce) begin
        px_r<=reset?8'd0:game_r;px_g<=reset?8'd0:game_g;px_b<=reset?8'd0:game_b;
        // HBlank must keep describing every line, including vertical blank: sys
        // arcade_video samples VBlank only on a falling HBlank edge, so an HBlank
        // folded with DE never reports VBlank and forced-scandoubler output
        // produced no frames (sim/run_video_chain.sh: 0 frames old, 8 new).
        px_hb<=reset || (sync_vb ? sync_hb : !pixel_display);px_vb<=sync_vb;
        px_hs<=sync_h;px_vs<=sync_v;
        sync_h<=native_hs;sync_v<=native_vs;sync_vb<=native_vb;sync_hb<=native_hb;
    end
end
// MeatCore credits overlay: native 320x256 stage, ahead of the scaler and
// rotation. Raw (unmasked) controller/keyboard/mouse/OSD inputs dismiss it.
wire credits_dismiss=|(pad0|pad1|pad2|pad3|pad4|pad5) | |buttons | ps2_key[9] |
                     |ps2_mouse[2:0] | OSD_STATUS;
wire [7:0] credits_r,credits_g,credits_b;
wire credits_hs,credits_vs,credits_hb,credits_vb,credits_de,credits_active;
credits_overlay #(.WIDTH(320),.HEIGHT(256),.SCALE_LOG2(0),.SCROLL_FRAMES(4)) credits (
    .clk_video(clk_sys),.reset(reset),.ce_pixel(px_ce),
    .menu_trigger(status[120]),.dismiss(credits_dismiss),
    .r_in(px_r),.g_in(px_g),.b_in(px_b),.hs_in(px_hs),.vs_in(px_vs),
    .hblank_in(px_hb),.vblank_in(px_vb),
    .r_out(credits_r),.g_out(credits_g),.b_out(credits_b),
    .hs_out(credits_hs),.vs_out(credits_vs),
    .hblank_out(credits_hb),.vblank_out(credits_vb),
    .de_out(credits_de),.active(credits_active)
);
wire [7:0] vm_r,vm_g,vm_b;
wire vm_hs,vm_vs,vm_de,vm_ce;
arcade_video #(.WIDTH(320),.DW(24)) video_output (
    .clk_video(clk_sys),.ce_pix(px_ce),.RGB_in({credits_r,credits_g,credits_b}),
    .HBlank(credits_hb),.VBlank(credits_vb),.HSync(credits_hs),.VSync(credits_vs),
    .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(vm_ce),.VGA_R(vm_r),.VGA_G(vm_g),.VGA_B(vm_b),
    .VGA_HS(vm_hs),.VGA_VS(vm_vs),.VGA_DE(vm_de),.VGA_SL(VGA_SL),
    .fx(3'd0),.forced_scandoubler(forced_scandoubler && !direct_video),.gamma_bus(gamma_bus)
);
wire [7:0] crt_r,crt_g,crt_b;
wire crt_hs,crt_vs,crt_hb,crt_vb,hs_ref;
reg hs_ref_d=0;
reg [7:0] read_acc=0;
wire signed [4:0] hsize=status[66:62];
wire [7:0] read_period=8'd96+{{3{hsize[4]}},hsize};
wire read_tick=({1'b0,read_acc}+9'd8)>={1'b0,read_period};
always @(posedge clk_sys) begin
    hs_ref_d<=hs_ref;
    if(!crt_on || (hs_ref && !hs_ref_d)) read_acc<=0;
    else if(read_tick) read_acc<=read_acc+8'd8-read_period;
    else read_acc<=read_acc+8'd8;
end
wire signed [8:0] hposition=status[104:98]<=48 ? $signed({2'b0,status[104:98]})
    : $signed({2'b0,status[104:98]})-9'sd97;
// V-Shift only delays VSync by whole lines. The picture is displayed on lines 1..256 of the
// 282-line frame and VS starts at line 260 (3 lines), so the pulse stays clear of the picture
// for -2 .. +19 lines (one blank line on either side; sim/run_crt_bench.sh). Menu: 0..+19, -2, -1.
wire [4:0] voffset_raw=status[60:56];
wire signed [5:0] voffset=voffset_raw<=5'd19 ? $signed({1'b0,voffset_raw}) :
                          voffset_raw<=5'd21 ? $signed({1'b0,voffset_raw})-6'sd22 : 6'sd0;
wire output_ce=crt_on ? read_tick : vm_ce;
crt_adjust #(.VTOTAL(282),.HTOTAL(512),.HPOS_MODE(1)) geometry (
    .clk(clk_sys),.pxl_cen(vm_ce),.pxl2_cen(output_ce),.active(crt_on),
    .hsize(hsize),.hoffset(hposition),.voffset(voffset),
    .r_in(vm_r),.g_in(vm_g),.b_in(vm_b),.hs_in(vm_hs),.vs_in(vm_vs),
    .hb_in(!vm_de),.vb_in(credits_vb),.r_out(crt_r),.g_out(crt_g),.b_out(crt_b),
    .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.hs_ref_out(hs_ref)
);
assign VGA_R=crt_r;assign VGA_G=crt_g;assign VGA_B=crt_b;
assign VGA_HS=crt_hs;assign VGA_VS=crt_vs;assign CE_PIXEL=output_ce;
wire rotate_en=(status[2:1]==1 || status[2:1]==2) && !direct_video;
wire [1:0] ar=status[122:121];
wire [11:0] arx=!ar ? (rotate_en?12'd3:12'd4) : {10'd0,ar}-12'd1;
wire [11:0] ary=!ar ? (rotate_en?12'd4:12'd3) : 12'd0;
wire [2:0] scale=status[7:5]==2 ? 3'd4 : status[7:5]==3 ? 3'd2 : status[7:5];
video_freak framing (
    .CLK_VIDEO(clk_sys),.CE_PIXEL(output_ce),.VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),.VGA_DE_IN(!crt_hb),
    .ARX(arx),.ARY(ary),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(direct_video?3'd0:scale)
);
wire [28:0] rotation_address;
wire [63:0] rotation_data;
wire [7:0] rotation_be;
wire rotation_write,rotation_overflow;
`ifdef MISTER_FB
screen_rotate rotate (
    .CLK_VIDEO(clk_sys),.CE_PIXEL(output_ce),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
    .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
    .rotate_ccw(status[2:1]==1),.no_rotate(!rotate_en),.flip(1'b0),
    .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
    .DDRAM_BUSY(1'b0),.DDRAM_ADDR(rotation_address),.DDRAM_DIN(rotation_data),
    .DDRAM_BE(rotation_be),.DDRAM_WE(rotation_write)
);
`else
assign {rotation_address,rotation_data,rotation_be,rotation_write}=0;
`endif
assign DDRAM_CLK=clk_sys;assign DDRAM_BURSTCNT=1;assign DDRAM_RD=0;
ZeroTeam_rotation rotation_buffer (
    .clk(clk_sys),.reset(!pll_locked),.address(rotation_address),.data(rotation_data),
    .be(rotation_be),.write_pixel(rotation_write),.busy(DDRAM_BUSY),
    .ddr_address(DDRAM_ADDR),.ddr_data(DDRAM_DIN),.ddr_be(DDRAM_BE),
    .ddr_write(DDRAM_WE),.overflow(rotation_overflow)
);
