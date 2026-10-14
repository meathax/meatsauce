//============================================================================
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
//
//============================================================================

// Physical CrystalSystem board, host ROM loader, native scanout/audio and SRAM persistence.
module emu (`include "sys/emu_ports.vh");
assign ADC_BUS = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign DDRAM_CLK = clk_sys;
assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = status[124:123];
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;
assign LED_USER = ioctl_download | ioctl_upload | rotation_overflow;

`include "build_id.v"
localparam CONF_STR = {
    "CrystalSystem;;",

    "H0O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[64:63],Orientation,Original,Rotate CW (HDMI),Rotate CCW (HDMI),Flipped;",
    "H0O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
    "H1O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "O[124:123],Audio mix,None,25%,50%,Mono;",
    "P1,CRT Adjust;",
    "P1O[96],CRT Adjust,Off,On;",
    "H2P1O[116:112],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[104:101],CRT H-Position,0,+6,+12,+18,+24,+30,+36,+42,-48,-42,-36,-30,-24,-18,-12,-6;",
    "H2P1O[108:105],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
    "O[81],Test switch,Off,On;",
    "DIP;",
    "R[120],Credits;",
    "J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause,Service Credit,Service Menu;",
    "jn,A,B,X,Y,Start,Select,L,-,-;",
    "T[0],Reset;", "R[0],Reset and close OSD;",
    "v,1;", "V,v",`BUILD_DATE
};
wire clk_sys, pll_locked;
wire sdram_capture_clk;
pll pll (.refclk(CLK_50M), .rst(1'b0), .outclk_0(clk_sys), .outclk_1(sdram_capture_clk), .locked(pll_locked));
// Forward the memory clock through a real DDR output cell, driven by the second PLL
// output (same frequency, 7.805 ns later than clk_sys). That shift places the SDRAM data
// window on a master-clock edge so DQ is captured on clk_sys itself: one logic clock.
altddio_out #(.width(1), .intended_device_family("Cyclone V"),
    .power_up_high("OFF"), .oe_reg("UNREGISTERED")) sdram_clock_forward (
    .outclock(sdram_capture_clk), .outclocken(1'b1), .datain_h(1'b1), .datain_l(1'b0),
    .aclr(1'b0), .aset(1'b0), .sclr(1'b0), .sset(1'b0), .oe(1'b1),
    .dataout(SDRAM_CLK), .oe_out()
);

(* async_reg = "true" *) reg [3:0] reset_ready = 0;
wire startup_reset = !pll_locked;
always @(posedge clk_sys or posedge startup_reset)
    if (startup_reset) reset_ready <= 0;
    else reset_ready <= {reset_ready[2:0],1'b1};
wire [127:0] status;
wire [1:0] buttons;
wire memory_reset = !reset_ready[3];
wire restore_reset;
wire reset = RESET | memory_reset | status[0] | buttons[1] | restore_reset;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3, joystick_4, joystick_5;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire forced_scandoubler, direct_video;
wire [21:0] gamma_bus;
wire ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_upload_req;
wire rom_wait, nvram_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout, ioctl_din;
wire native_ce, native_hblank, native_vblank, native_hs, native_vs;
wire [23:0] native_rgb;
wire [11:0] native_x, native_y;
wire board_ce, board_hblank, board_vblank, board_hs, board_vs;
wire [23:0] board_rgb;
wire [11:0] board_x, board_y;
wire video_de;
wire rotation_overflow;
`ifdef MISTER_FB
wire rotation_90 = FB_EN && FB_WIDTH < FB_HEIGHT;
`else
wire rotation_90 = 0;
`endif

wire [64:0] rtc;
hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(), .RTC(rtc),
    .gamma_bus(gamma_bus), .forced_scandoubler(forced_scandoubler),
    .direct_video(direct_video), .video_rotated(rotation_90 && !direct_video),
    .buttons(buttons), .status(status), .status_menumask({13'd0,!status[96],(!direct_video && (status[64:63] == 2'd1 || status[64:63] == 2'd2)),direct_video}),
    .joystick_0(joystick_0), .joystick_1(joystick_1),
    .joystick_2(joystick_2), .joystick_3(joystick_3),
    .joystick_4(joystick_4), .joystick_5(joystick_5),
    .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
    .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
    .ioctl_wr(ioctl_wr), .ioctl_rd(ioctl_rd), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_din(ioctl_din),
    .ioctl_upload_req(ioctl_upload_req), .ioctl_upload_index(8'd4), .ioctl_wait(rom_wait | nvram_wait)
);
wire [31:0] p1_p2_n, p3_p4_n;
wire [7:0] system_n, dips_n;
wire pause_cpu, persistence_pause;
// DS1302 time from MiSTer's RTC (as MAME seeds it from the host clock). The board re-initialises the
// DS1302 on every reset, so the latest RTC value is re-seeded after each reset and on the first update.
// MiSTer RTC: [7:0] s, [15:8] m, [23:16] h, [31:24] date, [39:32] month, [47:40] year, [55:48] weekday (BCD).
logic rtc_toggle = 0, rtc_have = 0, rtc_pending = 0, rtc_seed_valid = 0, reset_seen = 0;
logic [55:0] rtc_seed_bcd = 0;
always_ff @(posedge clk_sys) begin
    rtc_toggle <= rtc[64];
    rtc_seed_valid <= 0;
    reset_seen <= reset;
    if (rtc[64] != rtc_toggle) begin
        rtc_have <= 1; rtc_pending <= !rtc_have;
        rtc_seed_bcd <= {rtc[47:40], rtc[55:48], rtc[39:32], rtc[31:24], rtc[23:16], rtc[15:8], rtc[7:0]};
    end
    if (reset_seen && !reset) rtc_pending <= rtc_have;
    if (rtc_pending && !reset) begin rtc_seed_valid <= 1; rtc_pending <= 0; end
end
// MRA board record (index 1): game id and populated cartridge flash banks (0/none = crysking layout).
wire [7:0] game_id;
wire [3:0] cart_banks;
cs_board_config board_config (
    .clk(clk_sys), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .game_id(game_id), .cart_banks(cart_banks)
);
// MRA index 3: protection PIC firmware (MAME "pic" region, little-endian 16-bit words). Office Yeoin
// Cheonha (game id 4) runs it like MAME master; the other sets keep MAME's code patches and no PIC.
logic pic_load_we=0;
logic [13:0] pic_load_address=0;
logic [15:0] pic_load_data=0;
logic [7:0] pic_low_byte=0;
always_ff @(posedge clk_sys) begin
    pic_load_we<=0;
    if(ioctl_download && ioctl_wr && ioctl_index==16'd3) begin
        if(!ioctl_addr[0]) pic_low_byte<=ioctl_dout;
        else begin pic_load_we<=1;pic_load_address<=ioctl_addr[14:1];pic_load_data<={ioctl_dout,pic_low_byte}; end
    end
end
wire pic_enable=game_id==8'd4;
cs_mister_controls controls (
    .clk(clk_sys), .reset(reset), .game_id(game_id),
    .joystick_0(joystick_0), .joystick_1(joystick_1), .joystick_2(joystick_2),
    .osd_open(OSD_STATUS), .persistence_pause(persistence_pause), .test_switch(status[81]),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .p1_p2_n(p1_p2_n), .p3_p4_n(p3_p4_n), .system_n(system_n), .dips_n(dips_n), .pause_cpu(pause_cpu)
);
// Clock ratios remain SYSCLK / 2 for the CPU; pausing never gates a clock.
logic cpu_phase=0;
always_ff @(posedge clk_sys)
    if(memory_reset) cpu_phase<=0;
    else cpu_phase<=!cpu_phase;
wire rom_ready, loading, loader_error, memory_initialized;
wire [15:0] sdram_data_out;
wire sdram_data_oe;
wire [1:0] sdram_dqm;
assign SDRAM_DQ=sdram_data_oe ? sdram_data_out : 16'hzzzz;
assign {SDRAM_DQMH,SDRAM_DQML}=sdram_dqm;
wire board_ddr_busy, board_ddr_rd, board_ddr_we;
wire [28:0] board_ddr_addr;
wire [7:0] board_ddr_burst, board_ddr_be;
wire [63:0] board_ddr_din;
wire rotate_ddr_busy, rotate_ddr_we;
wire [28:0] rotate_ddr_addr;
wire [7:0] rotate_ddr_be;
wire [63:0] rotate_ddr_din;
wire backup_valid,backup_ready,backup_write,backup_rsp_valid;
wire [13:0] backup_address;
wire [31:0] backup_data,backup_rsp_data;
wire [3:0] backup_strobe;
wire board_req_valid,board_req_ready,board_req_write;
wire [3:0] board_req_target,board_req_strobe;
wire cpu_trace_valid,cpu_trace_ready,cpu_trace_rsp_valid,cpu_trace_write;
wire [31:0] cpu_trace_rsp_data;
logic cpu_bus_pending=0;
always_ff @(posedge clk_sys) begin
    if(memory_reset) cpu_bus_pending<=0;
    else if(cpu_trace_valid && cpu_trace_ready) cpu_bus_pending<=1;
    else if(cpu_trace_rsp_valid) cpu_bus_pending<=0;
end
cs_nvram_host nvram (
    .clk(clk_sys),.memory_reset(memory_reset),.osd_open(OSD_STATUS),
    .cpu_quiet(!cpu_bus_pending && !cpu_trace_valid),
    .nvram_written(board_req_valid && board_req_ready && board_req_target==5 &&
                   board_req_write && |board_req_strobe),
    .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),
    .ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_din(ioctl_din),
    .ioctl_wait(nvram_wait),.ioctl_upload_req(ioctl_upload_req),
    .pause_cpu(persistence_pause),.dirty(),.restore_reset(restore_reset),
    .backup_valid(backup_valid),.backup_ready(backup_ready),
    .backup_address(backup_address),.backup_data(backup_data),
    .backup_strobe(backup_strobe),.backup_write(backup_write),
    .backup_rsp_valid(backup_rsp_valid),.backup_rsp_data(backup_rsp_data)
);
wire audio_valid;
wire signed [15:0] board_audio_left,board_audio_right;
// Hold each 44.19 kHz SPU sample stable for its whole period: sys/audio_out.sv only accepts
// AUDIO_L/R values that are equal on two consecutive clk_audio samples (see cs_audio_interp).
wire signed [15:0] audio_left, audio_right;
assign AUDIO_L=audio_left;
assign AUDIO_R=audio_right;
cs_audio_interp #(.PERIOD(1944)) audio_smooth (
    .clk(clk_sys), .mute(reset || loading || !rom_ready), .sample_valid(audio_valid),
    .in_left(board_audio_left), .in_right(board_audio_right),
    .out_left(audio_left), .out_right(audio_right)
);
// The game CRTC is in reset while loading/resetting; keep a regular native
// raster so direct video and the scaler retain sync (pass-through when running).
wire hold_ce, hold_hblank, hold_vblank, hold_hs, hold_vs;
wire [11:0] hold_x, hold_y;
wire [23:0] hold_rgb;
cs_video_hold video_hold (
    .clk(clk_sys), .game_active(!(reset || !rom_ready || loading)),
    .game_ce(board_ce), .game_hblank(board_hblank), .game_vblank(board_vblank),
    .game_hs(board_hs), .game_vs(board_vs), .game_x(board_x), .game_y(board_y), .game_rgb(board_rgb),
    .ce(hold_ce), .hblank(hold_hblank), .vblank(hold_vblank),
    .hs(hold_hs), .vs(hold_vs), .x(hold_x), .y(hold_y), .rgb(hold_rgb)
);
assign native_ce=hold_ce; assign native_hblank=hold_hblank; assign native_vblank=hold_vblank;
assign native_hs=hold_hs; assign native_vs=hold_vs; assign native_x=hold_x; assign native_y=hold_y; assign native_rgb=hold_rgb;
cs_crystal_platform #(.SDRAM_REGISTERED_IO(1),.SDRAM_PHASED_CAPTURE(1)) board (
    .clk(clk_sys),.reset(reset),.memory_reset(memory_reset),.cart_banks(cart_banks),
    .rtc_seed_valid(rtc_seed_valid),.rtc_seed_bcd(rtc_seed_bcd),.video_flip(status[64:63] == 2'd3),
    .pic_enable(pic_enable),.pic_load_we(pic_load_we),.pic_load_address(pic_load_address),.pic_load_data(pic_load_data),
    .ce(cpu_phase && !pause_cpu),
    .p1_p2_n(p1_p2_n),.p3_p4_n(p3_p4_n),.system_n(system_n),.dips_n(dips_n),
    .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),.ioctl_wait(rom_wait),
    .rom_ready(rom_ready),.loading(loading),.loader_error(loader_error),
    .memory_initialized(memory_initialized),
    .sdram_test_done(),.sdram_test_errors(),.sdram_test_first_addr(),.sdram_test_first_actual(),
    .req_valid(board_req_valid),.req_ready(board_req_ready),.req_write(board_req_write),
    .req_target(board_req_target),.req_strobe(board_req_strobe),
    .cpu_trace_valid(cpu_trace_valid),.cpu_trace_ready(cpu_trace_ready),
    .cpu_trace_rsp_valid(cpu_trace_rsp_valid),.cpu_trace_address(),
    .cpu_trace_write(cpu_trace_write),.cpu_trace_rsp_data(cpu_trace_rsp_data),
    .pc(),.sr(),.fault(),.fault_pc(),.fault_opcode(),
    .retire(),.irq_vector(),.cpu_event_code(),.flash_bank(),
    .mmio_valid(),.mmio_address(),
    .gpu_fault(),.gpu_packets(),.dma_fault(),
    .audio_underrun(),.audio_fault(),
    .video_fault(),.video_underrun(),
    .cache_enabled(),.cache_hits(),.cache_misses(),
    .video_tick(board_ce),.video_hblank(board_hblank),.video_vblank(board_vblank),
    .video_hsync(board_hs),.video_vsync(board_vs),.video_x(board_x),.video_y(board_y),
    .video_r(board_rgb[23:16]),.video_g(board_rgb[15:8]),.video_b(board_rgb[7:0]),
    .audio_valid(audio_valid),.audio_left(board_audio_left),.audio_right(board_audio_right),
    .backup_valid(backup_valid),.backup_ready(backup_ready),.backup_address(backup_address),
    .backup_data(backup_data),.backup_strobe(backup_strobe),.backup_write(backup_write),
    .backup_rsp_valid(backup_rsp_valid),.backup_rsp_data(backup_rsp_data),
    .sdram_data_in(SDRAM_DQ),.sdram_data_out(sdram_data_out),.sdram_data_oe(sdram_data_oe),
    .sdram_capture_clk(sdram_capture_clk),.sdram_clk(),.sdram_cke(SDRAM_CKE),.sdram_cs_n(SDRAM_nCS),
    .sdram_ras_n(SDRAM_nRAS),.sdram_cas_n(SDRAM_nCAS),.sdram_we_n(SDRAM_nWE),
    .sdram_dqm(sdram_dqm),.sdram_ba(SDRAM_BA),.sdram_address(SDRAM_A),
    .DDRAM_BUSY(board_ddr_busy),.DDRAM_BURSTCNT(board_ddr_burst),
    .DDRAM_ADDR(board_ddr_addr),.DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(board_ddr_rd),
    .DDRAM_DIN(board_ddr_din),.DDRAM_BE(board_ddr_be),.DDRAM_WE(board_ddr_we)
);
cs_ddr_share ddr_share (
    .clk(clk_sys),.reset(memory_reset),.board_rd(board_ddr_rd),.board_we(board_ddr_we),
    .board_addr(board_ddr_addr),.board_burst(board_ddr_burst),
    .board_be(board_ddr_be),.board_din(board_ddr_din),.board_busy(board_ddr_busy),
    .rotate_we(rotate_ddr_we),.rotate_addr(rotate_ddr_addr),.rotate_be(rotate_ddr_be),
    .rotate_din(rotate_ddr_din),.rotate_busy(rotate_ddr_busy),
    .DDRAM_BUSY(DDRAM_BUSY),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_RD(DDRAM_RD),.DDRAM_WE(DDRAM_WE),.DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_BE(DDRAM_BE),.DDRAM_DIN(DDRAM_DIN)
);
// MeatCore Credits (status bit 120) on the native 320x240 raster, before the
// scaler and HDMI rotation tap. Raw inputs dismiss it; the game keeps running.
wire credits_dismiss = |(joystick_0 | joystick_1 | joystick_2 |
                         joystick_3 | joystick_4 | joystick_5) |
                       |buttons | ps2_key[9] | |ps2_mouse[2:0] | OSD_STATUS;
wire [7:0] credits_r, credits_g, credits_b;
wire credits_hs, credits_vs, credits_hb, credits_vb, credits_de, credits_active;
credits_overlay #(.WIDTH(320), .HEIGHT(240), .SCALE_LOG2(0), .SCROLL_FRAMES(4)) credits (
    .clk_video(clk_sys), .reset(memory_reset), .ce_pixel(native_ce),
    .menu_trigger(status[120]), .dismiss(credits_dismiss),
    .r_in(native_rgb[23:16]), .g_in(native_rgb[15:8]), .b_in(native_rgb[7:0]),
    .hs_in(native_hs), .vs_in(native_vs), .hblank_in(native_hblank), .vblank_in(native_vblank),
    .r_out(credits_r), .g_out(credits_g), .b_out(credits_b),
    .hs_out(credits_hs), .vs_out(credits_vs), .hblank_out(credits_hb), .vblank_out(credits_vb),
    .de_out(credits_de), .active(credits_active)
);
// Raster position delayed by the overlay's three enabled stages for the rotation tap.
logic [11:0] credits_x0, credits_x1, credits_x2, credits_y0, credits_y1, credits_y2;
always_ff @(posedge clk_sys)
    if (native_ce) begin
        {credits_x2, credits_x1, credits_x0} <= {credits_x1, credits_x0, native_x};
        {credits_y2, credits_y1, credits_y0} <= {credits_y1, credits_y0, native_y};
    end
wire [23:0] credits_rgb = {credits_r, credits_g, credits_b};
wire credits_frame = native_ce && credits_x2 == 0 && credits_y2 == 0;
// OSD CRT Adjust (rmonic79/MiSTer-CRT-Adjust via the BrezzaSoft_Crystal_System_MiSTer glue, both
// GPL-3.0-or-later): H-Size / H-Position / V-Shift move the picture content through a line buffer while
// the syncs stay native, so a CRT keeps its lock. Off = true bypass; gated off while the scandoubler is
// active. That module uses active-high syncs; this core's are active-low.
logic crt_vb_d = 0, crt_hb_d = 0;
logic [9:0] crt_width_count = 0;
logic crt_wide = 0;
always_ff @(posedge clk_sys) begin
    crt_vb_d <= credits_vb;
    if (native_ce) begin
        crt_hb_d <= credits_hb;
        if (!credits_hb && !credits_vb) crt_width_count <= crt_hb_d ? 10'd1 : crt_width_count + 10'd1;
        if (credits_hb && !crt_hb_d && !credits_vb) crt_wide <= crt_width_count > 10'd320; // Top Blade V: 360
    end
end
wire crt_vb_next = (credits_y2 + 12'd1 >= 12'd240) && (credits_y2 + 12'd1 < 12'd262);
wire av_ce, av_hb, av_vb, av_hs_p, av_vs_p;
wire [23:0] av_rgb;
crystal_crt_adjust crt_adjust (
    .clk_sys(clk_sys), .ce_pix(native_ce), .frame_event(credits_vb && !crt_vb_d),
    .osd_on(status[96]), .osd_hsize(status[116:112]), .osd_hpos(status[104:101]), .osd_vshift(status[108:105]),
    .sd_off(status[46:44] == 3'd0 && !forced_scandoubler), .vb_next(crt_vb_next), .wide(crt_wide),
    .rgb_in(credits_rgb), .hblank_in(credits_hb), .vblank_in(credits_vb),
    .hsync_in(!credits_hs), .vsync_in(!credits_vs),
    .ce_out(av_ce), .rgb_out(av_rgb), .hblank_out(av_hb), .vblank_out(av_vb),
    .hsync_out(av_hs_p), .vsync_out(av_vs_p), .active(), .hsize_s(), .hpos_s(), .vsh_s()
);
// WIDTH 360: Top Blade V programs a 360-pixel picture on the same 455x262 raster.
arcade_video #(.WIDTH(360), .DW(24)) video (
    .clk_video(clk_sys), .ce_pix(av_ce), .RGB_in(av_rgb),
    .HBlank(av_hb), .VBlank(av_vb), .HSync(!av_hs_p), .VSync(!av_vs_p),
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(video_de), .VGA_SL(VGA_SL),
    .fx(status[46:44]),
    .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
);
wire [1:0] ar = status[122:121];
wire [11:0] arx = !ar ? ((rotation_90 && !direct_video) ? 12'd3 : 12'd4) : {10'd0,(ar-2'd1)};
wire [11:0] ary = !ar ? ((rotation_90 && !direct_video) ? 12'd4 : 12'd3) : 12'd0;
cs_video_freak scale (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS), .VGA_DE_IN(video_de),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT), .VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY), .ARX(arx), .ARY(ary),
    .ROTATE_90(rotation_90 && !direct_video), .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE(direct_video ? 3'd0 : status[68:66])
);
`ifdef MISTER_FB
assign FB_FORMAT = 5'b00110;
assign FB_FORCE_BLANK = 0;
cs_screen_rotate rotate (
    .clk(clk_sys), .reset(reset || loading || !rom_ready), .ce_pix(native_ce), .frame_start(credits_frame),
    .display_enable(credits_de), .pixel_x(credits_x2), .pixel_y(credits_y2),
    .rgb(credits_rgb), .orientation((crt_wide || status[64:63] == 2'd3) ? 2'd0 : status[64:63]), .direct_video(direct_video), // 320-wide frame buffer
    .fb_vbl(FB_VBL), .ddram_busy(rotate_ddr_busy), .fb_en(FB_EN), .fb_width(FB_WIDTH),
    .fb_height(FB_HEIGHT), .fb_base(FB_BASE), .fb_stride(FB_STRIDE),
    .ddram_addr(rotate_ddr_addr), .ddram_din(rotate_ddr_din), .ddram_be(rotate_ddr_be),
    .ddram_we(rotate_ddr_we), .overflow(rotation_overflow)
);
`else
assign {rotate_ddr_addr,rotate_ddr_din,rotate_ddr_be,rotate_ddr_we,rotation_overflow} = '0;
`endif
endmodule
