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

module emu #(
 // Native CRT/direct-video raster: 48 MHz/8 = 6 MHz pixels, 384x270 total =
 // 15.625 kHz / 57.87 Hz (MAME declares 58 Hz). MAME's 256x256 set_size is not
 // a raster: 256 lines at 15.0 kHz is outside what arcade CRTs lock to.
 // Active x0..255 / y16..239; HS x288..319 keeps darkmist's HS-to-active
 // distance (CRT Adjust centring); VS y254..256; both positive.
 parameter bit NATIVE_PROFILE=1,NATIVE_TIMING_VALIDATED=1,CRT_CONTROLS_VALIDATED=1,
 parameter integer NATIVE_PIXEL_DIV=8,NATIVE_HTOTAL=384,NATIVE_VTOTAL=270,
 parameter integer NATIVE_HACTIVE_START=0,NATIVE_HACTIVE_END=256,NATIVE_VACTIVE_START=16,NATIVE_VACTIVE_END=240,
 parameter integer NATIVE_HS_START=288,NATIVE_HS_END=320,NATIVE_VS_START=254,NATIVE_VS_END=257,
 parameter bit NATIVE_HS_ACTIVE_LOW=0,NATIVE_VS_ACTIVE_LOW=0,
 parameter integer NATIVE_EOF_LINE=240,NATIVE_IRQ64_LINE=64,NATIVE_IRQ240_LINE=240,NATIVE_SUB_IRQ_LINE=240,
 // OSD ranges identical to darkmist: H-Size 0,+1,+2,-2,-1; H-Position/V-Shift -16..+15.
 parameter integer CRT_HSIZE_MIN=-2,CRT_HSIZE_MAX=2,CRT_HPOS_MIN=-16,CRT_HPOS_MAX=15,CRT_VPOS_MIN=-16,CRT_VPOS_MAX=15
)(

    `include "sys/emu_ports.vh"
);
wire clk_sys, pll_locked;
heavyunit_pll clock_source(.refclk(CLK_50M), .rst(RESET), .clk(clk_sys),
    .sdram_clk(SDRAM_CLK), .locked(pll_locked));
wire power_reset = RESET || !pll_locked;
reg [2:0] reset_sync = 3'b111;
always @(posedge clk_sys or posedge power_reset)
    if(power_reset) reset_sync <= 3'b111;
    else reset_sync <= {reset_sync[1:0],1'b0};
wire cold_reset = reset_sync[2];
wire [127:0] status;
wire [1:0] buttons;
wire warm_reset = status[0] || buttons[1];
`include "build_id.v"
`include "rtl/heavyunit_crt_menu.vh"
localparam CONF_STR = {
    "HeavyUnit;;",
    // Layout: Video Settings / Game Settings pages, DIP Switches, Credits, Reset.
    // Status bit allocation is unchanged; only grouping and labels differ.
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
    "P2O[42],Autosave Scores,On,Off;",
    "-;",
    "DIP;",
    "R[120],Credits;",
    "-;",
    "R[0],Reset;",
    "J1,Shot,Bomb,Start,Coin,Pause,Service,Game Pause;",
    "v,1;V,v",`BUILD_DATE
};
wire [31:0] joystick_0,joystick_1;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire forced_scandoubler,direct_video;
wire crt_available;
wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd;
wire [15:0] ioctl_index,ioctl_dout;
wire [26:0] ioctl_addr;
wire storage_wait;
wire [15:0] score_din;
wire score_upload_req;
wire [7:0] score_upload_index;
wire score_pause,score_reset_blocked,feature_error;
wire rotation_pause,rotation_busy,rotation_quiescent,rotation_writes_drained;
wire rotation_write,platform_metadata_error,platform_video_rotated;
wire [28:0] rotation_address;
wire [63:0] rotation_data;
wire [7:0] rotation_be,rotation_burst;
wire platform_fb_enable;
wire [4:0] platform_fb_format;
wire [11:0] platform_fb_width,platform_fb_height;
wire [31:0] platform_fb_base;
wire [13:0] platform_fb_stride;
`ifdef MISTER_FB
wire fb_supported=1'b1;
wire fb_consumer_vblank=FB_VBL,fb_consumer_low_latency=FB_LL;
`else
wire fb_supported=1'b0;
wire fb_consumer_vblank=1'b0,fb_consumer_low_latency=1'b0;
`endif
hps_io #(.CONF_STR(CONF_STR),.WIDE(1)) hps_io (
    .clk_sys,.HPS_BUS,.EXT_BUS(),.gamma_bus,
    .status,.buttons,.status_menumask({27'd0,!status[54],!(crt_available && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID),!direct_video,direct_video,(!sync_qualified || direct_video)}),.video_rotated(presentation_video_rotated),
    .joystick_0,.joystick_1,.ps2_key,.forced_scandoubler,.direct_video,
    .ioctl_download,.ioctl_upload,.ioctl_index,.ioctl_addr,.ioctl_dout,
    .ioctl_wr,.ioctl_rd,.ioctl_wait(storage_wait),.ioctl_din(score_din),
    .ioctl_upload_req(score_upload_req),.ioctl_upload_index(score_upload_index)
);
reg [31:0] key_p1,key_p2;
reg key_pause,key_service,key_game_pause,key_toggle;
always @(posedge clk_sys) begin
    if(cold_reset) begin
        key_p1<=0;key_p2<=0;key_pause<=0;key_service<=0;
        key_game_pause<=0;key_toggle<=ps2_key[10];
    end else if(key_toggle != ps2_key[10]) begin
        key_toggle<=ps2_key[10];
        case(ps2_key[7:0])
            8'h75: key_p1[3]<=ps2_key[9];
            8'h72: key_p1[2]<=ps2_key[9];
            8'h6b: key_p1[1]<=ps2_key[9];
            8'h74: key_p1[0]<=ps2_key[9];
            8'h14: if(ps2_key[8]) key_p2[4]<=ps2_key[9]; else key_p1[4]<=ps2_key[9];
            8'h11: if(ps2_key[8]) key_p2[5]<=ps2_key[9]; else key_p1[5]<=ps2_key[9];
            8'h16: key_p1[6]<=ps2_key[9];
            8'h1e: key_p2[6]<=ps2_key[9];
            8'h2e: key_p1[7]<=ps2_key[9];
            8'h36: key_p2[7]<=ps2_key[9];
            8'h1d: key_p2[3]<=ps2_key[9];
            8'h1b: key_p2[2]<=ps2_key[9];
            8'h1c: key_p2[1]<=ps2_key[9];
            8'h23: key_p2[0]<=ps2_key[9];
            8'h4d: key_pause<=ps2_key[9];
            8'h06: key_service<=ps2_key[9];
            8'h0c: key_game_pause<=ps2_key[9];
            default: begin end
        endcase
    end
end
wire [31:0] joy_p1=joystick_0|key_p1;
wire [31:0] joy_p2=joystick_1|key_p2;
wire service=joy_p1[9]||joy_p2[9]||key_service;
wire firmware_pause=joy_p1[10]||joy_p2[10]||key_game_pause;
// Direct output has its own valid Normal/180 choice; HDMI keeps four choices.
wire presentation_rotate_180=direct_video ? status[53] : status[45:44]==2'd3;
wire [7:0] system_inputs_n=~{1'b0,service,2'b00,joy_p2[7],joy_p1[7],joy_p2[6],joy_p1[6]};
wire [7:0] player1_inputs_n=~{1'b0,firmware_pause,joy_p1[5:4],joy_p1[0],joy_p1[1],joy_p1[2],joy_p1[3]};
wire [7:0] player2_inputs_n=~{2'b00,joy_p2[5:4],joy_p2[0],joy_p2[1],joy_p2[2],joy_p2[3]};
reg [2:0] selected_set;
reg [7:0] dsw1,dsw2;
always @(posedge clk_sys) begin
    if(cold_reset) begin selected_set<=0;dsw1<=8'hfe;dsw2<=8'hf7;end
    else if(ioctl_download && ioctl_wr) begin
        if(ioctl_index==16'd1 && ioctl_addr==0) selected_set<=ioctl_dout[2:0];
        if(ioctl_index==16'd254 && ioctl_addr==0) begin dsw1<=ioctl_dout[7:0];dsw2<=ioctl_dout[15:8];end
    end
end
// Full sixteen-bit host indices are decoded inside the private game candidate.
wire ram_ready,game_ready,game_reset,memory_idle,initialized,drained,transfer_active,rom_loaded;
wire [2:0] loaded_set,error_code;
wire main_event_64,main_event_240,sub_vblank,eof,vis_start,prepare_line,line_commit;
wire [7:0] prepare_y,scan_x,scan_y;
wire scan_valid,raw_ce_pixel,raw_hs,raw_vs,raw_hb,raw_vb,raw_de,sync_qualified;
wire line_ready,line_pending,tile_busy,object_busy,object_hold,object_completed;
wire [31:0] frame_number,missed_lines,blocked_preparations,object_pass_cycles;
wire [15:0] object_late_swaps;
wire [9:0] objects_done;
wire graphics_protocol_error;
wire credits_active,credits_pause;
wire pause_button=joy_p1[8]||joy_p2[8]||key_pause;
reg pause_button_old,user_pause_request,pause_effective;
always @(posedge clk_sys) begin
    if(cold_reset || (warm_reset && !score_reset_blocked)) begin
        pause_button_old<=0;user_pause_request<=0;pause_effective<=0;
    end else begin
        pause_button_old<=pause_button;
        if(pause_button && !pause_button_old) user_pause_request<=!user_pause_request;
        if(eof) pause_effective<=user_pause_request||(OSD_STATUS&&status[41])||credits_pause;
    end
end
// Development compatibility scheduler. Its idle sync outputs and fractional
// cadence are NOT native CRT/direct-video qualification; P7 replaces this
// binding only after the original PCB clock/raster evidence is established.
generate if(NATIVE_PROFILE) begin: native_raster
 heavyunit_native_timing #(
  .PIXEL_DIV(NATIVE_PIXEL_DIV),
  .HTOTAL(NATIVE_HTOTAL),
  .VTOTAL(NATIVE_VTOTAL),
  .HACTIVE_START(NATIVE_HACTIVE_START),
  .HACTIVE_END(NATIVE_HACTIVE_END),
  .VACTIVE_START(NATIVE_VACTIVE_START),
  .VACTIVE_END(NATIVE_VACTIVE_END),
  .HS_START(NATIVE_HS_START),
  .HS_END(NATIVE_HS_END),
  .VS_START(NATIVE_VS_START),
  .VS_END(NATIVE_VS_END),
  .HS_ACTIVE_LOW(NATIVE_HS_ACTIVE_LOW),
  .VS_ACTIVE_LOW(NATIVE_VS_ACTIVE_LOW),
  .EOF_LINE(NATIVE_EOF_LINE),
  .IRQ64_LINE(NATIVE_IRQ64_LINE),
  .IRQ240_LINE(NATIVE_IRQ240_LINE),
  .SUB_IRQ_LINE(NATIVE_SUB_IRQ_LINE)
 ) timing (
    .clk(clk_sys),.reset(game_reset),.tile_busy,.line_pending,
    .main_event_64,.main_event_240,.sub_vblank,.eof,.vis_start,
    .prepare_line,.line_commit,.prepare_y,.scan_x,.scan_y,.scan_valid,
    .raw_ce_pixel,.raw_hs,.raw_vs,.raw_hb,.raw_vb,.raw_de,.sync_qualified,
    .frame_number,.missed_lines,.blocked_preparations
,.native_timing_valid(NATIVE_TIMING_VALIDATED)
 );
end else begin: compatibility_raster
 heavyunit_reference_timing timing (
    .clk(clk_sys),.reset(game_reset),.tile_busy,.line_pending,
    .main_event_64,.main_event_240,.sub_vblank,.eof,.vis_start,
    .prepare_line,.line_commit,.prepare_y,.scan_x,.scan_y,.scan_valid,
    .raw_ce_pixel,.raw_hs,.raw_vs,.raw_hb,.raw_vb,.raw_de,.sync_qualified,
    .frame_number,.missed_lines,.blocked_preparations
);
end endgenerate

wire renderer_valid,audio_sample,audio_ready;
wire [23:0] renderer_rgb;
wire signed [15:0] game_audio;
wire [15:0] dq_out;
wire dq_oe;
assign SDRAM_DQ=dq_oe ? dq_out : 16'hzzzz;
heavyunit_game game (
    .clk(clk_sys),.reset(cold_reset),.soft_reset(warm_reset),.pause(pause_effective),.rotate_180(presentation_rotate_180),
    .system_inputs_n,.player1_inputs_n,.player2_inputs_n,.dsw1,.dsw2,
    .ioctl_download,.ioctl_upload,.ioctl_wr,.ioctl_rd,.ioctl_index,.ioctl_addr,.ioctl_dout,.ioctl_wait(storage_wait),
    .osd_open(OSD_STATUS),.autosave(!status[42]),.ioctl_din(score_din),
    .ioctl_upload_req(score_upload_req),.ioctl_upload_index(score_upload_index),
    .score_pause,.score_reset_blocked,.feature_error,
    .ddram_busy(DDRAM_BUSY),.ddram_data_ready(DDRAM_DOUT_READY),.ddram_data(DDRAM_DOUT),
    .ddram_rd(DDRAM_RD),.ddram_we(DDRAM_WE),.ddram_addr(DDRAM_ADDR),
    .ddram_burstcnt(DDRAM_BURSTCNT),.ddram_be(DDRAM_BE),.ddram_writedata(DDRAM_DIN),
    // The attached producer publishes every descriptor into the DDR owner.
    // Reset admission waits for its frame-boundary quiescence and queue drain.
    .rotate_we(rotation_write),.rotate_addr(rotation_address),.rotate_data(rotation_data),.rotate_be(rotation_be),
    .rotation_quiescent,.rotation_pause,.rotation_busy,.rotation_writes_drained,
    .selected_set,.loaded_set,.ram_ready,.game_ready,.game_reset,.memory_idle,
    .initialized,.drained,.transfer_active,.rom_loaded,.error_code,
    .main_event_64,.main_event_240,.sub_vblank,.eof,.vis_start,
    .prepare_line,.line_commit,.prepare_y,.scan_x,.scan_y,.scan_valid,
    .pixel_valid(renderer_valid),.rgb(renderer_rgb),.audio(game_audio),.audio_sample,.audio_ready,
    .line_ready,.line_pending,.tile_busy,.object_busy,.object_hold,.object_completed,
    .object_pass_cycles,.object_late_swaps,.objects_done,.graphics_protocol_error,
    .dq_in(SDRAM_DQ),.dq_out,.dq_oe,.sdram_addr(SDRAM_A),.sdram_bank(SDRAM_BA),
    .sdram_dqml(SDRAM_DQML),.sdram_dqmh(SDRAM_DQMH),.sdram_ncs(SDRAM_nCS),
    .sdram_nwe(SDRAM_nWE),.sdram_nras(SDRAM_nRAS),.sdram_ncas(SDRAM_nCAS),
    .sdram_cke(SDRAM_CKE),.sdram_clk()
);
wire [23:0] video_rgb;
	wire presentation_ce,presentation_hs,presentation_vs,presentation_de;
wire video_hb,video_vb,video_valid,alignment_error;
wire aligned_ce,aligned_hs,aligned_vs,aligned_de;
reg [7:0] aligned_x[0:3];
always @(posedge clk_sys)begin
    if(game_reset)begin for(integer i=0;i<4;i=i+1)aligned_x[i]<=0;end
    else begin
        aligned_x[0]<=scan_x;
        for(integer i=1;i<4;i=i+1)aligned_x[i]<=aligned_x[i-1];
    end
end
heavyunit_video_output output_alignment (
    .clk(clk_sys),.reset(game_reset),.raw_ce_pixel,.raw_hs,.raw_vs,.raw_hb,.raw_vb,.raw_de,
    .renderer_rgb,.renderer_valid,.ce_pixel(aligned_ce),.hs(aligned_hs),.vs(aligned_vs),
    .hb(video_hb),.vb(video_vb),.de(aligned_de),.pixel_valid(video_valid),
    .rgb(video_rgb),.alignment_error
);
wire [1:0] ar=status[122:121];
wire [11:0] aspect_x=(ar==0) ? 12'd4 : {10'd0,(ar-2'd1)};
wire [11:0] aspect_y=(ar==0) ? 12'd3 : 12'd0;
// Quarter-turn presentation requires a usable framebuffer path. Renderer
// inversion remains available independently and is applied exactly once.
wire [1:0] presentation_orientation=presentation_rotate_180 ? 2'd3 :
    ((fb_supported && !direct_video) ? status[45:44] : 2'd0);
// The donor reports configured no_rotate, even while publication is disabled.
// HPS metadata instead describes the actually enabled quarter-turn path.
wire presentation_video_rotated=fb_supported && !direct_video && platform_fb_enable &&
    (presentation_orientation==2'd1 || presentation_orientation==2'd2);
// Portable Credits: all video signals and producer coordinates share latency.
wire [23:0] credits_rgb;
wire credits_ce,credits_hs,credits_vs,credits_hb,credits_vb,credits_de,credits_eof;
wire [7:0] credits_pixel_x;
wire credits_dismiss=|(joystick_0|joystick_1) || |buttons || ps2_key[9] || OSD_STATUS;
heavyunit_credits #(.LOGICAL_RASTER(!NATIVE_PROFILE)) credits_display (
 .clk(clk_sys),.reset(cold_reset),.ce_pixel(aligned_ce),.menu_trigger(status[120]),
 .dismiss(credits_dismiss),.frame_boundary(eof),.orientation(presentation_orientation),
 .rgb(video_rgb),.hs(aligned_hs),.vs(aligned_vs),.hb(video_hb),.vb(video_vb),.de(aligned_de),
 .pixel_x(aligned_x[3]),.rgb_out(credits_rgb),.hs_out(credits_hs),.vs_out(credits_vs),
 .hb_out(credits_hb),.vb_out(credits_vb),.de_out(credits_de),.ce_out(credits_ce),
 .frame_boundary_out(credits_eof),.pixel_x_out(credits_pixel_x),
 .active(credits_active),.pause_active(credits_pause)
);
heavyunit_video_platform #(
 .NATIVE_PIXEL_DIV(NATIVE_PIXEL_DIV),.NATIVE_HTOTAL(NATIVE_HTOTAL),.NATIVE_VTOTAL(NATIVE_VTOTAL),.NATIVE_HACTIVE_START(NATIVE_HACTIVE_START),.NATIVE_HS_REFERENCE(NATIVE_HS_ACTIVE_LOW ? NATIVE_HS_END : NATIVE_HS_START),
 .CRT_HSIZE_MIN(CRT_HSIZE_MIN),.CRT_HSIZE_MAX(CRT_HSIZE_MAX),.CRT_HPOS_MIN(CRT_HPOS_MIN),.CRT_HPOS_MAX(CRT_HPOS_MAX),.CRT_VPOS_MIN(CRT_VPOS_MIN),.CRT_VPOS_MAX(CRT_VPOS_MAX)
) presentation (
    .clk(clk_sys),.reset(cold_reset),.rgb(credits_rgb),
    .ce_pixel(credits_ce),.hs(credits_hs),.vs(credits_vs),.hb(credits_hb),.vb(credits_vb),.de(credits_de),
    .pixel_x(credits_pixel_x),.reference_profile(!NATIVE_PROFILE),.native_sync_qualified(sync_qualified),
    .native_frame_boundary(credits_eof),.crt_enable(status[54] && CRT_CONTROLS_VALIDATED && CRT_MENU_RANGES_VALID),.crt_hsize($signed(5'(crt_menu_decode(int'(status[59:55]),CRT_HSIZE_MIN,CRT_HSIZE_MAX,5)))),.crt_hposition($signed(7'(crt_menu_decode(int'(status[66:60]),CRT_HPOS_MIN,CRT_HPOS_MAX,7)))),.crt_vposition($signed(5'(crt_menu_decode(int'(status[71:67]),CRT_VPOS_MIN,CRT_VPOS_MAX,5)))),.crt_active(),.crt_available(crt_available),.crt_range_clamped(),
    .direct_video,.forced_scandoubler,.effect(status[52:50]),.gamma_bus,
    .hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),.aspect_x,.aspect_y,.scale_mode(status[47:46]),
    .orientation(presentation_orientation),.rotation_enable(fb_supported && game_ready && !direct_video),.rotation_pause,
    .writes_drained(rotation_writes_drained),
    .fb_vblank(fb_consumer_vblank),.fb_low_latency(fb_consumer_low_latency),.ddram_busy(rotation_busy),
    .clk_video(CLK_VIDEO),.output_ce(presentation_ce),.vga_hs(presentation_hs),.vga_vs(presentation_vs),.vga_de(presentation_de),
    .vga_r(VGA_R),.vga_g(VGA_G),.vga_b(VGA_B),.vga_sl(VGA_SL),.video_arx(VIDEO_ARX),.video_ary(VIDEO_ARY),
    .output_sync_qualified(),.raw_rgb(),.raw_ce(),.raw_hs(),.raw_vs(),.raw_hb(),.raw_vb(),.raw_de(),
    .producer_quiescent(rotation_quiescent),.metadata_error(platform_metadata_error),
    .fb_enable(platform_fb_enable),.video_rotated(platform_video_rotated),.fb_format(platform_fb_format),
    .fb_width(platform_fb_width),.fb_height(platform_fb_height),.fb_base(platform_fb_base),.fb_stride(platform_fb_stride),
    .write_burstcount(rotation_burst),.write_byteenable(rotation_be),.write_address(rotation_address),
    .write_data(rotation_data),.write_valid(rotation_write)
);
// Presentation owns standard VGA outputs; aligned raw taps remain inside it.
// Reference metadata is independent of framebuffer publication readiness.
    // Raw analog/direct video remains unqualified; sys/ is unchanged.
    wire metadata_overlap;
    wire reference_ce,reference_hs,reference_vs,reference_de;
    wire metadata_ce,metadata_de,metadata_vb;
    wire [8:0] metadata_x;
    wire [7:0] metadata_y;
    // The scaler/HDMI PLL needs valid timing before ROM loading and across
    // game resets. Framebuffer publication and blanking still gate its image.
    heavyunit_framebuffer_timing framebuffer_timing (
        .clk(clk_sys),.reset(cold_reset),.raw_ce(metadata_ce),
        .raw_de(metadata_de),.raw_vb(metadata_vb),.raw_x(metadata_x),.raw_y(metadata_y)
    );
    heavyunit_reference_metadata reference_metadata (
        .clk(clk_sys),.reset(cold_reset),
        .enable(!NATIVE_PROFILE && fb_supported && !direct_video),
        .raw_ce(metadata_ce),.raw_de(metadata_de),.raw_vb(metadata_vb),
        .raw_x(metadata_x),.raw_y(metadata_y),.ce(reference_ce),.hs(reference_hs),.vs(reference_vs),.de(reference_de),
        .overlap_error(metadata_overlap)
    );
    assign {CE_PIXEL,VGA_HS,VGA_VS,VGA_DE}=NATIVE_PROFILE ?
        {presentation_ce,presentation_hs,presentation_vs,presentation_de} :
        {reference_ce,reference_hs,reference_vs,reference_de};
    assign VGA_DISABLE = !sync_qualified;
    assign {VGA_F1,VGA_SCALER,HDMI_BLACKOUT,HDMI_FREEZE,HDMI_BOB_DEINT} = '0;
// Aspect and integer viewport outputs are produced by presentation.
assign AUDIO_L=game_audio;
assign AUDIO_R=game_audio;
assign AUDIO_S=1'b1;
assign AUDIO_MIX=0;
assign LED_USER=transfer_active||(|error_code)||graphics_protocol_error||alignment_error||feature_error||platform_metadata_error;
assign {LED_DISK,LED_POWER,BUTTONS}='0;
assign ADC_BUS='z;
assign USER_OUT='1;
assign {UART_RTS,UART_TXD,UART_DTR}='0;
assign {SD_SCK,SD_MOSI,SD_CS}='z;
// Fast-load/rotation arbitration and score-upload ownership are integrated in
// P6/P7 after the actual game checkpoint; this is not final platform sign-off.
assign DDRAM_CLK=clk_sys;
`ifdef MISTER_FB
assign FB_EN=platform_fb_enable;
assign FB_FORMAT=platform_fb_format;
assign FB_WIDTH=platform_fb_width;assign FB_HEIGHT=platform_fb_height;
assign FB_BASE=platform_fb_base;assign FB_STRIDE=platform_fb_stride;
// Measurement DE runs before the producer has published a usable descriptor.
assign FB_FORCE_BLANK=!game_ready || !platform_fb_enable || platform_metadata_error || feature_error;
`ifdef MISTER_FB_PALETTE
assign {FB_PAL_CLK,FB_PAL_ADDR,FB_PAL_DOUT,FB_PAL_WR}='0;
`endif
`endif
`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,SDRAM2_CLK,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='z;
`endif
endmodule
