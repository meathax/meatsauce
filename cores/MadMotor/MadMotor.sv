module emu (
    `include "sys/emu_ports.vh"
);

localparam integer CRT_HSIZE_MIN = -1, CRT_HSIZE_MAX = 1;
localparam integer CRT_HPOS_MIN = -8, CRT_HPOS_MAX = 0;
localparam integer CRT_VPOS_MIN = -1, CRT_VPOS_MAX = 1;
`include "rtl/framework/heavyunit_crt_menu.vh"

localparam CONF_STR = {
    "Mad Motor / Bandit;;",
    "P1,Video Settings;",
    "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
`ifdef MISTER_FB
    "H1P1O[45:44],Rotation,Original,90 CW,90 CCW,180;",
`endif
    "P1O[47:46],Scaling,Normal,V-Integer,HV-Integer;",
    "H0P1O[52:50],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "H3P1O[54],CRT Adjust,Off,On;",
    "H3H4P1O[59:55],CRT H-Size,", CRT_HSIZE_OPTIONS, ";",
    "H3H4P1O[66:60],CRT H-Position,", CRT_HPOS_OPTIONS, ";",
    "H3H4P1O[71:67],CRT V-Shift,", CRT_VPOS_OPTIONS, ";",
    "P2,Game Settings;",
    "P2O[72],OSD Pause,Off,On;",
    "-;",
    "DIP;",
    "R[0],Reset;",
    "J1,Accelerate / Fire,Attack / Bomb,Start,Coin,Pause,Service;",
    "J2,Accelerate / Fire,Attack / Bomb,Start,Coin,Pause,Service;",
    "v,1;"
};

wire clk_sys;
wire pll_locked;
wire reset_sys;
wire async_platform_reset = RESET || !pll_locked;
madmotor_pll platform_pll (
    .refclk(CLK_50M),
    .reset(RESET),
    .outclk(clk_sys),
    .locked(pll_locked)
);
madmotor_reset platform_reset (
    .clk(clk_sys),
    .async_reset(async_platform_reset),
    .sync_reset(reset_sys)
);
madmotor_sdram_clock platform_sdram_clock (
    .clk(clk_sys),
    .reset(reset_sys),
    .outclk(SDRAM_CLK)
);

wire [127:0] status;
wire [1:0] buttons;
wire video_rotated;
wire [31:0] joystick_0, joystick_1,mapped_joystick_0,mapped_joystick_1;
wire [15:0] right_stick_0,right_stick_1;
logic bandit=0;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire forced_scandoubler, direct_video;
wire ioctl_download, ioctl_wr, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [4:0] crt_hsize_code = status[59:55];
wire [6:0] crt_hposition_code = status[66:60];
wire [4:0] crt_vposition_code = status[71:67];
wire signed [4:0] crt_hsize = 5'(crt_menu_decode(int'(crt_hsize_code), CRT_HSIZE_MIN, CRT_HSIZE_MAX, 5));
wire signed [6:0] crt_hposition = 7'(crt_menu_decode(int'(crt_hposition_code), CRT_HPOS_MIN, CRT_HPOS_MAX, 7));
wire signed [4:0] crt_vposition = 5'(crt_menu_decode(int'(crt_vposition_code), CRT_VPOS_MIN, CRT_VPOS_MAX, 5));
wire crt_available;
wire [15:0] status_menumask;

`ifdef MISTER_FB
localparam bit FRAMEBUFFER_SUPPORTED = 1'b1;
`else
localparam bit FRAMEBUFFER_SUPPORTED = 1'b0;
`endif

assign status_menumask = {
    11'd0,
    !status[54],
    !crt_available,
    1'b0,
    !FRAMEBUFFER_SUPPORTED || direct_video,
    direct_video
};

madmotor_hps_io #(.CONF_STR(CONF_STR)) host_io (
    .clk(clk_sys),
    .HPS_BUS(HPS_BUS),
    .gamma_bus(gamma_bus),
    .status(status),
    .buttons(buttons),
    .menu_mask(status_menumask),
    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .right_stick_0(right_stick_0),.right_stick_1(right_stick_1),
    .ps2_key(ps2_key),
    .forced_scandoubler(forced_scandoubler),
    .direct_video(direct_video),
    .video_rotated(video_rotated),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_address(ioctl_addr),
    .ioctl_data(ioctl_dout),
    .ioctl_wr(ioctl_wr),
    .ioctl_wait(ioctl_wait),
    .ioctl_upload(), .ioctl_rd(),
    .ioctl_read_data(8'd0), .upload_request(1'b0), .upload_index(8'd0)
);

wire [15:0] controls, dips;
wire [2:0] coins_n;
wire pause_request;
madmotor_controls controls_adapter (
    .clk_sys(clk_sys),
    .reset(reset_sys),
    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .ps2_key(ps2_key),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .mapped_joystick_0(mapped_joystick_0),.mapped_joystick_1(mapped_joystick_1),
    .controls(controls),
    .dips(dips),
    .coins_n(coins_n),
    .pause_request(pause_request)
);

// The MRA sends profile index 1 before its ROM stream. Reset the game
// through the existing download ownership while replacing the profile.
always_ff @(posedge clk_sys) begin
    if(reset_sys) bandit<=0;
    else if(ioctl_download && ioctl_wr && ioctl_index==16'd1 && ioctl_addr==0)
        bandit<=ioctl_dout==8'd1;
end
wire profile_download=ioctl_download && ioctl_index==16'd1;
wire soft_reset = profile_download || status[0] || buttons[1];
logic pause_latch;
always_ff @(posedge clk_sys) begin
    if (reset_sys || soft_reset)
        pause_latch <= 1'b0;
    else if (pause_request)
        pause_latch <= !pause_latch;
end
wire board_pause = pause_latch || (OSD_STATUS && status[72]);

wire load_mode, load_req, load_ok, initializing, rom_loaded;
wire loader_rom_loaded, rom_ioctl_download, rom_ioctl_wr, rom_ioctl_wait;
wire [15:0] rom_ioctl_index;
wire [26:0] rom_ioctl_addr;
wire [7:0] rom_ioctl_dout;
wire rotation_reset, rotation_owner_busy;
wire [7:0] rotation_queue_level, rotation_burstcount, rotation_byteenable;
wire [28:0] rotation_address;
wire [63:0] rotation_data;
wire rotation_we, rotation_rd;
wire [23:0] load_addr;
wire [15:0] load_data;
wire [1:0] load_mask;
wire audio_load_we;
wire [1:0] audio_load_region;
wire [17:0] audio_load_addr;
wire [7:0] audio_load_data;
wire mcu_rom_we;
wire [11:0] mcu_rom_addr;
wire [7:0] mcu_rom_data;
madmotor_rom_loader rom_loader (
    .bandit(bandit),
    .clk_sys(clk_sys),
    .reset(reset_sys),
    .ioctl_download(rom_ioctl_download),
    .ioctl_wr(rom_ioctl_wr),
    .ioctl_index(rom_ioctl_index),
    .ioctl_addr(rom_ioctl_addr),
    .ioctl_dout(rom_ioctl_dout),
    .ioctl_wait(rom_ioctl_wait),
    .load_mode(load_mode),
    .load_req(load_req),
    .load_addr(load_addr),
    .load_data(load_data),
    .load_mask(load_mask),
    .load_ok(load_ok),
    .audio_load_we(audio_load_we),
    .audio_load_region(audio_load_region),
    .audio_load_addr(audio_load_addr),
    .audio_load_data(audio_load_data),
    .mcu_rom_we(mcu_rom_we),
    .mcu_rom_addr(mcu_rom_addr),
    .mcu_rom_data(mcu_rom_data),
    .rom_loaded(loader_rom_loaded)
);

// HPS byte uploads and DDR image replay share the same checked byte loader.
// The spool owns the physical DDR port until every accepted read has drained.
madmotor_ddr_rom_spool rom_spool (
    .clk_sys(clk_sys), .reset(reset_sys),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .rom_ioctl_download(rom_ioctl_download), .rom_ioctl_wr(rom_ioctl_wr),
    .rom_ioctl_index(rom_ioctl_index), .rom_ioctl_addr(rom_ioctl_addr),
    .rom_ioctl_dout(rom_ioctl_dout), .rom_ioctl_wait(rom_ioctl_wait),
    .rom_load_mode(load_mode), .rom_loaded_in(loader_rom_loaded),
    .rom_loaded(rom_loaded),
    .rot_queue_level(rotation_queue_level), .rot_ddram_burstcount(rotation_burstcount),
    .rot_ddram_address(rotation_address), .rot_ddram_data(rotation_data),
    .rot_ddram_byteenable(rotation_byteenable), .rot_ddram_we(rotation_we),
    .rot_ddram_rd(rotation_rd), .rot_ddram_busy(rotation_owner_busy),
    .rotation_reset(rotation_reset),
    .ddram_clk(DDRAM_CLK), .ddram_burstcount(DDRAM_BURSTCNT),
    .ddram_address(DDRAM_ADDR), .ddram_dout(DDRAM_DOUT),
    .ddram_dout_ready(DDRAM_DOUT_READY), .ddram_rd(DDRAM_RD),
    .ddram_din(DDRAM_DIN), .ddram_byteenable(DDRAM_BE),
    .ddram_we(DDRAM_WE), .ddram_busy(DDRAM_BUSY),
    .load_busy(), .load_error(), .owner_rom(), .protocol_error()
);

wire signed [15:0] audio_left, audio_right;
wire audio_sample_ce, audio_clipped;
wire [3:0] board_red, board_green, board_blue;
wire board_hs, board_vs, board_hblank, board_vblank, pixel_valid;
wire [8:0] pixel_x, pixel_y;
wire [23:0] board_rgb24;
wire [23:0] crt_rgb;
wire crt_ce, crt_hs, crt_vs, crt_hblank, crt_vblank;
wire crt_active, crt_range_clamped;
logic previous_board_vs;
always_ff @(posedge clk_sys) begin
    if (reset_sys)
        previous_board_vs <= 1'b0;
    else if (pixel_valid)
        previous_board_vs <= board_vs;
end
wire native_frame_boundary = pixel_valid && board_vs && !previous_board_vs;
wire crt_doubler_selected = !direct_video && (forced_scandoubler || (status[52:50] != 3'd0));
wire crt_framebuffer_selected = FRAMEBUFFER_SUPPORTED && !direct_video && (status[45:44] != 2'd0);
// Digitally qualified candidate raster; original PCB timebase remains open.
madmotor_native_crt_adjust #(
    .PIXEL_DIV(10), .HTOTAL(384), .VTOTAL(272), .HACTIVE_START(0), .HS_REFERENCE(304),
    .HSIZE_MIN(CRT_HSIZE_MIN), .HSIZE_MAX(CRT_HSIZE_MAX),
    .HPOS_MIN(CRT_HPOS_MIN), .HPOS_MAX(CRT_HPOS_MAX),
    .VPOS_MIN(CRT_VPOS_MIN), .VPOS_MAX(CRT_VPOS_MAX)
) crt_adjust (
    .clk(clk_sys),
    .reset(reset_sys),
    .native_frame_boundary(native_frame_boundary),
    .native_timing_valid(1'b1),
    .native_profile(1'b1),
    .path_selected(1'b1),
    .scandoubler_enabled(crt_doubler_selected),
    .quarter_turn_selected(crt_framebuffer_selected),
    .enable(status[54]),
    .hsize(crt_hsize),
    .hposition(crt_hposition),
    .vposition(crt_vposition),
    .ce_in(pixel_valid),
    .rgb_in(board_rgb24),
    .hs_in(board_hs),
    .vs_in(board_vs),
    .hb_in(board_hblank),
    .vb_in(board_vblank),
    .ce_out(crt_ce),
    .rgb_out(crt_rgb),
    .hs_out(crt_hs),
    .vs_out(crt_vs),
    .hb_out(crt_hblank),
    .vb_out(crt_vblank),
    .active(crt_active),
    .available(crt_available),
    .range_clamped(crt_range_clamped)
);

madmotor_board #(.SYS_HZ(60000000)) board (
    .bandit(bandit),.joystick_0(mapped_joystick_0),.joystick_1(mapped_joystick_1),
    .right_stick_0(right_stick_0),.right_stick_1(right_stick_1),.rgb24(board_rgb24),
    .clk(clk_sys),
    .reset(reset_sys),
    .soft_reset(soft_reset),
    .rom_loaded(rom_loaded),
    .pause(board_pause),
    .controls(controls),
    .dips(dips),
    .coins_n(coins_n),
    .load_mode(load_mode),
    .load_req(load_req),
    .load_addr(load_addr),
    .load_data(load_data),
    .load_mask(load_mask),
    .load_ok(load_ok),
    .initializing(initializing),
    .audio_load_we(audio_load_we),
    .audio_load_region(audio_load_region),
    .audio_load_addr(audio_load_addr),
    .audio_load_data(audio_load_data),
    .mcu_rom_we(mcu_rom_we),
    .mcu_rom_addr(mcu_rom_addr),
    .mcu_rom_data(mcu_rom_data),
    .audio_left(audio_left),
    .audio_right(audio_right),
    .audio_sample_ce(audio_sample_ce),
    .audio_clipped(audio_clipped),
    .sdram_dq(SDRAM_DQ),
    .sdram_a(SDRAM_A),
    .sdram_ba(SDRAM_BA),
    .sdram_dqml(SDRAM_DQML),
    .sdram_dqmh(SDRAM_DQMH),
    .sdram_nwe(SDRAM_nWE),
    .sdram_ncas(SDRAM_nCAS),
    .sdram_nras(SDRAM_nRAS),
    .sdram_ncs(SDRAM_nCS),
    .sdram_cke(SDRAM_CKE),
    .red(board_red),
    .green(board_green),
    .blue(board_blue),
    .hs(board_hs),
    .vs(board_vs),
    .hblank(board_hblank),
    .vblank(board_vblank),
    .pixel_valid(pixel_valid),
    .pixel_x(pixel_x),
    .pixel_y(pixel_y),
    .sound_latch(),
    .sound_irq(),
    .halted(),
    .debug_address(),
    .debug_request(),
    .debug_read(),
    .debug_write(),
    .debug_write_data(),
    .debug_read_data(),
    .debug_byte_enable()
);

wire [2:0] video_effect = direct_video ? 3'd0 : status[52:50];
wire [1:0] video_scale = status[47:46];
wire [2:0] video_freak_scale = (video_scale == 2'd2) ? 3'd4 : {1'b0, video_scale};
wire [1:0] aspect_mode = status[122:121];
wire [11:0] aspect_x = (!aspect_mode) ? 12'd4 : (aspect_mode - 1'd1);
wire [11:0] aspect_y = (!aspect_mode) ? 12'd3 : 12'd0;
wire [1:0] rotation_mode = direct_video ? 2'd3 : status[45:44]==0 ?
    (bandit?2'd0:2'd3) : status[45:44]-2'd1;
wire rotation_quarter_turn = (rotation_mode == 2'd0) || (rotation_mode == 2'd1);
wire [11:0] scale_active_width;
wire [11:0] scale_active_height;
`ifdef MISTER_FB
assign scale_active_width = FB_EN ? FB_WIDTH : (rotation_quarter_turn ? 12'd240 : 12'd256);
assign scale_active_height = FB_EN ? FB_HEIGHT : (rotation_quarter_turn ? 12'd256 : 12'd240);
`else
assign scale_active_width = 12'd256;
assign scale_active_height = 12'd240;
`endif
wire [11:0] scale_aspect_x = rotation_quarter_turn && (aspect_y != 12'd0)
    ? aspect_y : aspect_x;
wire [11:0] scale_aspect_y = rotation_quarter_turn && (aspect_y != 12'd0)
    ? aspect_x : aspect_y;
wire [12:0] scaled_aspect_x, scaled_aspect_y;
video_scale_int framebuffer_aware_scaling (
    .CLK_VIDEO(clk_sys),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .SCALE(direct_video ? 3'd0 : video_freak_scale),
    .hsize(scale_active_width),
    .vsize(scale_active_height),
    .arx_i(scale_aspect_x),
    .ary_i(scale_aspect_y),
    .arx_o(scaled_aspect_x),
    .ary_o(scaled_aspect_y)
);
wire [7:0] core_vga_r, core_vga_g, core_vga_b;
wire core_vga_hs, core_vga_vs, core_vga_de;
wire [1:0] core_vga_sl;
madmotor_arcade_video #(.WIDTH(256), .DW(24), .GAMMA(1)) video_pipeline (
    .clk_video(clk_sys),
    .ce_pix(crt_ce),
    .RGB_in(crt_rgb),
    .HBlank(crt_hblank),
    .VBlank(crt_vblank),
    .HSync(crt_hs),
    .VSync(crt_vs),
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(core_vga_r),
    .VGA_G(core_vga_g),
    .VGA_B(core_vga_b),
    .VGA_HS(core_vga_hs),
    .VGA_VS(core_vga_vs),
    .VGA_DE(core_vga_de),
    .VGA_SL(core_vga_sl),
    .fx(video_effect),
    .forced_scandoubler(forced_scandoubler && !direct_video),
    .gamma_bus(gamma_bus)
);

wire presentation_de;
video_freak presentation (
    .CLK_VIDEO(clk_sys),
    .CE_PIXEL(CE_PIXEL),
    .VGA_VS(core_vga_vs),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(presentation_de),
    .VIDEO_ARX(VIDEO_ARX),
    .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(core_vga_de),
    .ARX(scaled_aspect_x[11:0]),
    .ARY(scaled_aspect_y[11:0]),
    .CROP_SIZE(12'd0),
    .CROP_OFF(5'd0),
    .SCALE(3'd0)
);

assign VGA_R = core_vga_r;
assign VGA_G = core_vga_g;
assign VGA_B = core_vga_b;
assign VGA_HS = core_vga_hs;
assign VGA_VS = core_vga_vs;
assign VGA_DE = presentation_de;
assign VGA_F1 = 1'b0;
assign VGA_SL = core_vga_sl;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

`ifdef MISTER_FB
madmotor_framebuffer_rotation #(
    .INPUT_WIDTH(256),
    .INPUT_HEIGHT(240),
    .FIFO_DEPTH(64)
) rotate_video (
    .clk(clk_sys),
    .reset(rotation_reset),
    .rotation(rotation_mode),
    .ce_pixel(pixel_valid),
    .source_vs(board_vs),
    .source_de(!board_hblank && !board_vblank),
    .source_r(board_rgb24[23:16]),
    .source_g(board_rgb24[15:8]),
    .source_b(board_rgb24[7:0]),
    .fb_vblank(FB_VBL),
    .fb_low_latency(FB_LL),
    .ddram_busy(DDRAM_BUSY || rotation_owner_busy),
    .video_rotated(video_rotated),
    .fb_enable(FB_EN),
    .fb_format(FB_FORMAT),
    .fb_width(FB_WIDTH),
    .fb_height(FB_HEIGHT),
    .fb_base(FB_BASE),
    .fb_stride(FB_STRIDE),
    .ddram_clk(),
    .ddram_burstcount(rotation_burstcount),
    .ddram_address(rotation_address),
    .ddram_data(rotation_data),
    .ddram_byteenable(rotation_byteenable),
    .ddram_we(rotation_we),
    .ddram_rd(rotation_rd),
    .queue_level(rotation_queue_level),
    .accepted_writes(),
    .dropped_frames(),
    .frame_overflow(),
    .protocol_error()
);
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK = 1'b0;
assign FB_PAL_ADDR = 8'd0;
assign FB_PAL_DOUT = 24'd0;
assign FB_PAL_WR = 1'b0;
`endif
`else
assign video_rotated = 1'b0;
assign {rotation_queue_level, rotation_burstcount, rotation_address,
        rotation_data, rotation_byteenable, rotation_we, rotation_rd} = '0;
`endif

wire audio_transfer_ready, audio_transfer_overrun, audio_transfer_valid;
madmotor_audio_cdc audio_transfer(
    .src_clk(clk_sys), .dst_clk(CLK_AUDIO),
    .async_reset(async_platform_reset), .src_valid(audio_sample_ce),
    .src_left(audio_left), .src_right(audio_right),
    .src_ready(audio_transfer_ready), .overrun(audio_transfer_overrun),
    .dst_left(AUDIO_L), .dst_right(AUDIO_R), .dst_valid(audio_transfer_valid)
);
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'b00;
// BEGIN MADMOTOR MCP LED LAUNCH
(* preserve, dont_merge, dont_retime *) reg mcp_led_user_launch = 1'b0;
always @(posedge clk_sys) mcp_led_user_launch <= rom_loaded && !reset_sys;
// END MADMOTOR MCP LED LAUNCH
assign LED_USER = mcp_led_user_launch;
assign LED_POWER = 2'b00;
assign LED_DISK = 2'b00;
assign BUTTONS = 2'b00;

assign ADC_BUS = 4'bzzzz;
assign USER_OUT = 7'h7f;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;
endmodule
