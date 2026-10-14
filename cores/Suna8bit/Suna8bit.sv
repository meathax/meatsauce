module emu
(
    `include "sys/emu_ports.vh"
);

assign ADC_BUS = 'Z;
wire [1:0] pcb_start_leds;
wire [1:0] pcb_coin_counters;
wire [1:0] pcb_coin_lockouts;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign VGA_F1 = 0;
// The framework's own scaler/analog-disable controls, driven from the OSD
// rather than tied off, so a CRT user can take the raw 15 kHz path and an
// HDMI-only user can drop the analog output.
assign VGA_SCALER  = status[41];
assign VGA_DISABLE = status[42];
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire forced_scandoubler;
wire direct_video;
wire video_rotated;
wire [1:0] buttons;
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [8:0] hps_spinner_0;
wire [8:0] hps_spinner_1;
wire [7:0] hps_paddle_0;
wire [7:0] hps_paddle_1;
wire [24:0] ps2_mouse;
// Brick Zone spinner/paddle/mouse (rtl/suna8_dial.sv): $C108/$C10C dial
// positions, and whole frames of left/right for the v6.0 joystick program.
wire [7:0] brick_dial_1;
wire [7:0] brick_dial_2;
wire [1:0] brick_dial_left;
wire [1:0] brick_dial_right;
// SunA's P1/P2 ports use the shared JOY macro, whose bit 7 is the coin
// input.  MiSTer reserves joystick bits 8/9 for coin 1/2 and bit 6/7 for
// start 1/2, so do not pass the low byte through unchanged.
wire [7:0] suna_input_p1 = ~{
    joystick_0[8], joystick_0[6], joystick_0[5], joystick_0[4],
    joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]
};
wire [7:0] suna_input_p2 = ~{
    joystick_1[9], joystick_1[7], joystick_1[5], joystick_1[4],
    joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]
};
// Brick Zone's later board drops up/down and swaps the first two joystick
// lines for left/right-only controls; bits 2/3 are active-high configuration
// cheats and idle at one.
wire [7:0] suna_brick_input_p1 = ~{
    joystick_0[8], joystick_0[6], joystick_0[5], joystick_0[4],
    1'b0, 1'b0, joystick_0[0] | brick_dial_right[0], joystick_0[1] | brick_dial_left[0]
};
wire [7:0] suna_brick_input_p2 = ~{
    joystick_1[9], joystick_1[7], joystick_1[5], joystick_1[4],
    1'b0, 1'b0, joystick_1[0] | brick_dial_right[1], joystick_1[1] | brick_dial_left[1]
};
// Spark Man's BUTTONS port exposes P1/P2 bomb inputs. The MRA's <buttons>
// names are positional from joystick bit 4 (bit4 B1, bit5 B2, bit6 start1,
// bit7 start2, bit8 coin1, bit9 coin2), so Bomb is declared as the seventh
// name and arrives on bit 10. It was previously listed third, which pushed
// Start 1P onto bit 7 (read here as start 2) and Coin onto bit 9 (coin 2):
// a coin and start from the stick began a player-2 game, and player 1's
// joystick then moved nothing. The remaining protection bits idle high.
wire [7:0] suna_buttons = {
    1'b1, 6'h3f,
    ~joystick_1[10], ~joystick_0[10]
};
wire [127:0] status;
wire [10:0] ps2_key;
wire [21:0] gamma_bus;
wire ioctl_download;
wire ioctl_wr;
wire [15:0] ioctl_index_wide;
wire [26:0] ioctl_addr_wide;
wire [7:0] ioctl_dout;

wire ioctl_wait;
logic [7:0] dip_switch_1 = 8'hff;
logic [7:0] dip_switch_2 = 8'hff;
localparam CONF_STR = {
    "Suna8bit;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    // video_freak's SCALE encoding, in its own order: 0 normal,
    // 1 V-integer, 2 HV-integer-, 3 HV-integer+, 4 HV-integer.
    "O[36:34],Scale,Normal,V-Integer,HV-Integer-,HV-Integer+,HV-Integer;",
    "O[38:37],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
    "O[39],Force Scandoubler,Off,On;",
    "O[45:44],Spinner (Brick Zone),1x,2x,4x,0.5x;",
    "-;",
    "P2,CRT;",
    "P2-,15 kHz / analog output.;",
    "P2O[41],VGA Scaler,Off,On;",
    "P2O[42],Analog Video,On,Off;",
    "-;",
    // Hidden (status_menumask bit 0) until an MRA with a hiscore config
    // has loaded. Default (0) is On: scores save when the OSD opens.
    "H0O[60],Autosave Hiscores,On,Off;",
    "-;",
    // Parent MRAs provide the board-specific switch bytes at ioctl index
    // 254; expose the standard DIP section without hard-coding one title.
    "DIP;",
    "-;",
    "R0,Reset;",
    "V,v"
};

// Hiscore system: MAME hiscore.dat entries carried in each MRA (ioctl
// index 3), the saved table as the MRA's NVRAM (index 4). See the
// hiscore instance below and rtl/hiscore.v.
wire        ioctl_upload;
wire [7:0]  ioctl_din;
wire [15:0] hs_address;
wire [7:0]  hs_data_in;
wire [7:0]  hs_data_out;
wire        hs_write;
wire        hs_pause;
wire        hs_configured;
wire        hs_upload_req;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .forced_scandoubler(forced_scandoubler),
    .direct_video(direct_video),
    .video_rotated(video_rotated),
    .new_vmode(1'b0),
    .buttons(buttons),
    .status(status),
    .joystick_0(joystick_0),
    .joystick_1(joystick_1),
    .spinner_0(hps_spinner_0),
    .spinner_1(hps_spinner_1),
    .paddle_0(hps_paddle_0),
    .paddle_1(hps_paddle_1),
    .ps2_mouse(ps2_mouse),
    .status_menumask({15'd0, ~hs_configured}),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index_wide),
    .ioctl_addr(ioctl_addr_wide),
    .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(hs_upload_req),
    .ioctl_upload_index(8'd4),
    .ioctl_din(ioctl_din),
    .ioctl_rd(),
    .ps2_key(ps2_key),
    .gamma_bus(gamma_bus)
);
wire clk_sys;
wire clk_video;
wire clk_sys_locked;
pll pll
(
    .refclk(CLK_50M),
    .rst(1'b0),
    .outclk_0(clk_sys),
    .outclk_1(clk_video),
    .locked(clk_sys_locked)
);

// MiSTer Main sends an MRA <switches> block as byte writes on index 254.
// Keep idle-high power-up values for an MRA without that block, and do not
// clear a loaded selection on an emulated-machine reset.
always_ff @(posedge clk_sys) begin
    if (ioctl_wr && (ioctl_index_wide == 16'd254) &&
        (ioctl_addr_wide[26:1] == 26'd0)) begin
        if (ioctl_addr_wide[0])
            dip_switch_2 <= ioctl_dout;
        else
            dip_switch_1 <= ioctl_dout;
    end
end

// Do not let the core generate video or run state machines until its 24 MHz
// clock has acquired lock. The MiSTer framework can already be alive and
// showing its OSD while this local PLL is still settling.
wire reset = RESET | status[0] | buttons[1] | !clk_sys_locked;
wire ce_pix;
wire hblank;
wire vblank;
wire hsync;
wire vsync;
wire [7:0] video_r;
wire [7:0] video_g;
wire [7:0] video_b;
wire [8:0] video_x;
wire [8:0] video_y;
wire signed [15:0] audio_l;
wire signed [15:0] audio_r;
wire [2:0] profile_id;
wire profile_valid;
wire [24:0] image_size;
wire [31:0] image_crc;
wire [31:0] frame_counter;
wire core_ready;
wire debug_download_active;
wire [31:0] debug_framebuffer_write_count;
wire debug_sprite_collision;
wire debug_palette_collision;
wire [1:0] pcb_start_leds_core;
wire [1:0] pcb_coin_counters_core;
wire [1:0] pcb_coin_lockouts_core;
wire media_wr_valid;
wire [2:0] media_wr_region;
wire [24:0] media_wr_addr;
wire [24:0] media_wr_offset;
wire [7:0] media_wr_data;

wire media_write_busy;
wire [19:0] main_media_read_addr;
wire main_media_read_req;
wire [7:0] main_media_read_q;
wire main_media_read_ready;
wire [15:0] sound_media_read_addr;
wire sound_media_read_req;
wire [7:0] sound_media_read_q;
wire sound_media_read_ready;
wire [15:0] pcm_media_read_addr;
wire pcm_media_read_req;
wire [7:0] pcm_media_read_q;
wire pcm_media_read_ready;
wire media_bytes_dropped;
wire [19:0] gfx1_media_read_addr;
wire [7:0] gfx1_media_read_q;
wire [63:0] gfx1_media_line_q;
wire gfx1_media_read_ready;
wire [19:0] gfx2_media_read_addr;
wire [7:0] gfx2_media_read_q;
wire [63:0] gfx2_media_line_q;
wire gfx2_media_read_ready;
wire [15:0] sample_media_read_addr;
wire [7:0] sample_media_read_q;
wire sample_media_read_ready;
wire [7:0] prom_media_read_addr;
wire [7:0] prom_media_read_q;
wire prom_media_read_ready;

`ifdef VERILATOR
wire [15:0] dbg_cpu_addr;
wire [7:0] dbg_cpu_dout, dbg_cpu_din;
wire dbg_cpu_mreq_n, dbg_cpu_iorq, dbg_cpu_rd_n, dbg_cpu_wr_n, dbg_cpu_m1_n;
wire [15:0] dbg_sound_cpu_addr;
wire [7:0] dbg_sound_cpu_dout, dbg_sound_cpu_din;
wire dbg_sound_cpu_mreq_n, dbg_sound_cpu_iorq, dbg_sound_cpu_rd_n, dbg_sound_cpu_wr_n, dbg_sound_cpu_m1_n;
wire [15:0] dbg_pcm_cpu_addr;
wire [7:0] dbg_pcm_cpu_dout, dbg_pcm_cpu_din;
wire dbg_pcm_cpu_mreq_n, dbg_pcm_cpu_iorq, dbg_pcm_cpu_rd_n, dbg_pcm_cpu_wr_n, dbg_pcm_cpu_m1_n;
wire [31:0] dbg_renderer_write_count, dbg_renderer_done_count;
wire dbg_renderer_deadline_miss;
`endif

wire memory_reset = RESET | !clk_sys_locked;
wire media_ready;
wire media_initialized;
wire media_verify_active;
wire media_verify_failed;
wire [31:0] media_verify_crc;
wire media_busy;
wire [6:0] media_cache_miss;
wire media_transaction_active;
logic media_ready_meta;
logic media_ready_sys;

always_ff @(posedge clk_sys) begin
    if (memory_reset) begin
        media_ready_meta <= 1'b0;
        media_ready_sys  <= 1'b0;
    end else begin
        media_ready_meta <= media_ready;
        media_ready_sys  <= media_ready_meta;
    end
end

hiscore #(
    .HS_ADDRESSWIDTH(16),
    .HS_SCOREWIDTH(9),      // Hard Head's table is 401 bytes
    .CFG_ADDRESSWIDTH(4),
    .CFG_LENGTHWIDTH(2)     // hiscore.dat entry lengths above 255
) hi (
    .clk(clk_sys),
    .paused(hs_pause),
    .reset(reset),
    .autosave(~status[60]),
    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(hs_upload_req),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr_wide[24:0]),
    .ioctl_index(ioctl_index_wide[7:0]),
    .OSD_STATUS(OSD_STATUS),
    .data_from_hps(ioctl_dout),
    .data_from_ram(hs_data_out),
    .ram_address(hs_address),
    .data_to_hps(ioctl_din),
    .data_to_ram(hs_data_in),
    .ram_write(hs_write),
    .ram_intent_read(),
    .ram_intent_write(),
    .pause_cpu(hs_pause),
    .configured(hs_configured)
);

suna8_dial brick_dial
(
    .clk(clk_sys),
    .reset(reset),
    .enable(profile_id == 3'd5),
    .vblank(vblank),
    .spinner_1(hps_spinner_0),
    .spinner_2(hps_spinner_1),
    .paddle_1(hps_paddle_0),
    .paddle_2(hps_paddle_1),
    .mouse_toggle(ps2_mouse[24]),
    .mouse_dx({ps2_mouse[4], ps2_mouse[15:8]}),
    .sensitivity(status[45:44]),
    .dial_1(brick_dial_1),
    .dial_2(brick_dial_2),
    .emu_left(brick_dial_left),
    .emu_right(brick_dial_right)
);

suna8_core core
(
    .clk(clk_sys),
    .reset(reset),
    .media_ready(media_ready_sys && !media_write_busy),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_index(ioctl_index_wide[7:0]),
    .ioctl_addr(ioctl_addr_wide[24:0]),
    .ioctl_dout(ioctl_dout),
    .hs_pause(hs_pause),
    .hs_addr(hs_address),
    .hs_din(hs_data_in),
    .hs_wr(hs_write),
    .hs_dout(hs_data_out),
    .ce_pix(ce_pix),
    .hblank(hblank),
    .input_p1((profile_id == 3'd5) ? suna_brick_input_p1 : suna_input_p1),
    .input_p2((profile_id == 3'd5) ? suna_brick_input_p2 : suna_input_p2),
    .dip_1(dip_switch_1),
    .dip_2(dip_switch_2),
    .buttons(suna_buttons),
    .spinner_1(brick_dial_1),
    .spinner_2(brick_dial_2),
    // Brick Zone's c140 port defaults bit 0 low (the other config bits are
    // idle-high); Star Fighter's custom protection bits remain idle-high.
    .cheats((profile_id == 3'd5) ? 8'hfb :
            (profile_id == 3'd3) ? 8'hdf : 8'hff),
    .vblank(vblank),
    .hsync(hsync),
    .vsync(vsync),
    .video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_x(video_x),
    .video_y(video_y),
    .audio_l(audio_l),
    .audio_r(audio_r),
    .profile_id(profile_id),
    .profile_valid(profile_valid),
    .image_size(image_size),
    .image_crc(image_crc),
    .frame_counter(frame_counter),
    .core_ready(core_ready),
    .debug_download_active(debug_download_active),
    .debug_framebuffer_write_count(debug_framebuffer_write_count),
    .debug_sprite_collision(debug_sprite_collision),
    .debug_palette_collision(debug_palette_collision),
`ifdef VERILATOR
    .dbg_cpu_addr(dbg_cpu_addr),
    .dbg_cpu_dout(dbg_cpu_dout),
    .dbg_cpu_din(dbg_cpu_din),
    .dbg_cpu_mreq_n(dbg_cpu_mreq_n),
    .dbg_cpu_iorq(dbg_cpu_iorq),
    .dbg_cpu_rd_n(dbg_cpu_rd_n),
    .dbg_cpu_wr_n(dbg_cpu_wr_n),
    .dbg_cpu_m1_n(dbg_cpu_m1_n),
    .dbg_sound_cpu_addr(dbg_sound_cpu_addr),
    .dbg_sound_cpu_dout(dbg_sound_cpu_dout),
    .dbg_sound_cpu_din(dbg_sound_cpu_din),
    .dbg_sound_cpu_mreq_n(dbg_sound_cpu_mreq_n),
    .dbg_sound_cpu_iorq(dbg_sound_cpu_iorq),
    .dbg_sound_cpu_rd_n(dbg_sound_cpu_rd_n),
    .dbg_sound_cpu_wr_n(dbg_sound_cpu_wr_n),
    .dbg_sound_cpu_m1_n(dbg_sound_cpu_m1_n),
    .dbg_pcm_cpu_addr(dbg_pcm_cpu_addr),
    .dbg_pcm_cpu_dout(dbg_pcm_cpu_dout),
    .dbg_pcm_cpu_din(dbg_pcm_cpu_din),
    .dbg_pcm_cpu_mreq_n(dbg_pcm_cpu_mreq_n),
    .dbg_pcm_cpu_iorq(dbg_pcm_cpu_iorq),
    .dbg_pcm_cpu_rd_n(dbg_pcm_cpu_rd_n),
    .dbg_pcm_cpu_wr_n(dbg_pcm_cpu_wr_n),
    .dbg_pcm_cpu_m1_n(dbg_pcm_cpu_m1_n),
    .dbg_renderer_write_count(dbg_renderer_write_count),
    .dbg_renderer_done_count(dbg_renderer_done_count),
    .dbg_renderer_deadline_miss(dbg_renderer_deadline_miss),
`endif
    .start_leds(pcb_start_leds_core),
    .coin_counters(pcb_coin_counters_core),
    .coin_lockouts(pcb_coin_lockouts_core),
    .media_wr_valid(media_wr_valid),
    .media_wr_region(media_wr_region),
    .media_wr_addr(media_wr_addr),
    .media_wr_offset(media_wr_offset),
    .media_wr_data(media_wr_data),
    .main_media_read_addr(main_media_read_addr),
    .main_media_read_req(main_media_read_req),
    .main_media_read_q(main_media_read_q),
    .main_media_read_ready(main_media_read_ready),
    .sound_media_read_addr(sound_media_read_addr),
    .sound_media_read_req(sound_media_read_req),
    .sound_media_read_q(sound_media_read_q),
    .sound_media_read_ready(sound_media_read_ready),
    .pcm_media_read_addr(pcm_media_read_addr),
    .pcm_media_read_req(pcm_media_read_req),
    .pcm_media_read_q(pcm_media_read_q),
    .pcm_media_read_ready(pcm_media_read_ready),
    .gfx1_media_read_addr(gfx1_media_read_addr),
    .gfx1_media_read_q(gfx1_media_read_q),
    .gfx1_media_line_q(gfx1_media_line_q),
    .gfx1_media_read_ready(gfx1_media_read_ready),
    .gfx2_media_read_addr(gfx2_media_read_addr),
    .gfx2_media_read_q(gfx2_media_read_q),
    .gfx2_media_line_q(gfx2_media_line_q),
    .gfx2_media_read_ready(gfx2_media_read_ready),
    .sample_media_read_addr(sample_media_read_addr),
    .sample_media_read_q(sample_media_read_q),
    .sample_media_read_ready(sample_media_read_ready),
    .prom_media_read_addr(prom_media_read_addr),
    .prom_media_read_q(prom_media_read_q),
    .prom_media_read_ready(prom_media_read_ready)
);

suna8_media_sdram media
(
    .clk(clk_sys),
    .reset(memory_reset),
    .runtime_enable(profile_valid && media_ready_sys &&
                    !ioctl_download && !media_write_busy),
    .download_active(ioctl_download),
    .verify_enable(profile_valid && !ioctl_download && !media_write_busy),
    .verify_size(image_size),
    .verify_expected_crc(image_crc),
    .media_ready(media_ready),
    .media_initialized(media_initialized),
    .media_verify_active(media_verify_active),
    .media_verify_failed(media_verify_failed),
    .media_bytes_dropped(media_bytes_dropped),
    .media_verify_crc(media_verify_crc),
    .media_busy(media_busy),
    .debug_cache_miss(media_cache_miss),
    .debug_transaction_active(media_transaction_active),
    .media_wr_valid(media_wr_valid),
    .media_wr_addr(media_wr_addr),
    .media_wr_data(media_wr_data),
    .ioctl_wait(ioctl_wait),
    .media_write_busy(media_write_busy),
    .main_addr(main_media_read_addr),
    .main_req(main_media_read_req),
    .main_q(main_media_read_q),
    .main_ready(main_media_read_ready),
    .sound_addr(sound_media_read_addr),
    .sound_req(sound_media_read_req),
    .sound_q(sound_media_read_q),
    .sound_ready(sound_media_read_ready),
    .pcm_addr(pcm_media_read_addr),
    .pcm_req(pcm_media_read_req),
    .pcm_q(pcm_media_read_q),
    .pcm_ready(pcm_media_read_ready),
    .gfx1_addr(gfx1_media_read_addr),
    .gfx1_q(gfx1_media_read_q),
    .gfx1_line_q(gfx1_media_line_q),
    .gfx1_ready(gfx1_media_read_ready),
    .gfx2_addr(gfx2_media_read_addr),
    .gfx2_q(gfx2_media_read_q),
    .gfx2_line_q(gfx2_media_line_q),
    .gfx2_ready(gfx2_media_read_ready),
    .sample_addr(sample_media_read_addr),
    .sample_q(sample_media_read_q),
    .sample_ready(sample_media_read_ready),
    .prom_addr(prom_media_read_addr),
    .prom_q(prom_media_read_q),
    .prom_ready(prom_media_read_ready),
    .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_A(SDRAM_A),
    .SDRAM_BA(SDRAM_BA),
    .SDRAM_CLK(SDRAM_CLK),
    .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCS(SDRAM_nCS)
);

// The normal raster is held reset until the image/profile/media contract
// opens, so it cannot diagnose a failure in that same contract. Keep an
// independent timing source alive after PLL lock and select it automatically
// until every boot gate opens (or permanently after a CRC failure).
logic diag_ce_pix;
logic diag_hblank;
logic diag_vblank;
logic diag_hsync;
logic diag_vsync;
logic [7:0] diag_r;
logic [7:0] diag_g;
logic [7:0] diag_b;
logic [31:0] diag_frame_counter;

suna8_boot_diag boot_diag
(
    .clk(clk_sys),
    .timing_reset(!clk_sys_locked),
    .machine_reset(reset),
    .download_active(debug_download_active),
    .profile_valid(profile_valid),
    .media_initialized(media_initialized),
    .media_write_busy(media_write_busy),
    .media_verify_active(media_verify_active),
    .media_verify_failed(media_verify_failed),
    .media_bytes_dropped(media_bytes_dropped),
    .core_ready(core_ready),
    .profile_id(profile_id),
    .ce_pix(diag_ce_pix),
    .hblank(diag_hblank),
    .vblank(diag_vblank),
    .hsync(diag_hsync),
    .vsync(diag_vsync),
    .video_r(diag_r),
    .video_g(diag_g),
    .video_b(diag_b),
    .frame_counter(diag_frame_counter)
);

wire use_boot_diag = reset || !core_ready || media_verify_failed;
wire source_ce_pix = use_boot_diag ? diag_ce_pix : ce_pix;
wire [23:0] source_rgb = use_boot_diag
    ? {diag_r, diag_g, diag_b}
    : {video_r, video_g, video_b};
wire source_hblank = use_boot_diag ? diag_hblank : hblank;
wire source_vblank = use_boot_diag ? diag_vblank : vblank;
wire source_hsync = use_boot_diag ? diag_hsync : hsync;
wire source_vsync = use_boot_diag ? diag_vsync : vsync;

// The selected native pixel enable belongs to the 24 MHz source domain, but
// MiSTer's video framework requires CLK_VIDEO above 40 MHz. Transfer each
// complete native pixel as a bundled word without modifying vendored code.

logic video_ce_video;
logic [23:0] video_rgb_video;
logic video_hblank_video;
logic video_vblank_video;
logic video_hsync_video;
logic video_vsync_video;

suna8_video_cdc video_cdc
(
    .src_clk(clk_sys),
    .dst_clk(clk_video),
    .reset(!clk_sys_locked),
    .src_ce(source_ce_pix),
    .src_rgb(source_rgb),
    .src_hblank(source_hblank),
    .src_vblank(source_vblank),
    .src_hsync(source_hsync),
    .src_vsync(source_vsync),
    .dst_ce(video_ce_video),
    .dst_rgb(video_rgb_video),
    .dst_hblank(video_hblank_video),
    .dst_vblank(video_vblank_video),
    .dst_hsync(video_hsync_video),
    .dst_vsync(video_vsync_video)
);

assign CLK_VIDEO = clk_video;

// Scandoubler Fx: 0 none, 1 HQ2x, 2 CRT 25%, 3 CRT 50%. VGA_SL carries the
// scanline weight for the last two; the scandoubler itself runs whenever an
// effect is selected, the OSD forces it, or the framework asks for it.
wire [1:0] scan_fx = status[38:37];
wire       fx_scandoubler = (scan_fx != 2'd0) || status[39] || forced_scandoubler;
assign VGA_SL = (scan_fx == 2'd2) ? 2'b01 :
                (scan_fx == 2'd3) ? 2'b10 : 2'b00;

video_mixer #(.LINE_LENGTH(260), .HALF_DEPTH(0), .GAMMA(1)) video_out
(
    .CLK_VIDEO(clk_video),
    .ce_pix(video_ce_video),
    .CE_PIXEL(CE_PIXEL),
    .scandoubler(fx_scandoubler),
    .hq2x(scan_fx == 2'd1),
    .gamma_bus(gamma_bus),
    .R(video_rgb_video[23:16]),
    .G(video_rgb_video[15:8]),
    .B(video_rgb_video[7:0]),
    .HBlank(video_hblank_video),
    .VBlank(video_vblank_video),
    .HSync(video_hsync_video),
    .VSync(video_vsync_video),
    .HDMI_FREEZE(1'b0),
    .freeze_sync(),
    .VGA_R(VGA_R),
    .VGA_G(VGA_G),
    .VGA_B(VGA_B),
    .VGA_HS(VGA_HS),
    .VGA_VS(VGA_VS),
    .VGA_DE(vga_de_raw)
);

// Integer-scaling and CRT geometry. video_freak owns VIDEO_ARX/ARY, so the
// aspect-ratio option and the Scale option both act through it instead of
// the previous fixed assignment, which the OSD could not change.
wire vga_de_raw;
wire [1:0] ar = status[122:121];
wire [11:0] arx_in = (ar == 2'd1) ? 12'd0 : (vertical_profile ? 12'd3 : 12'd4);
wire [11:0] ary_in = (ar == 2'd1) ? 12'd0 : (vertical_profile ? 12'd4 : 12'd3);

video_freak video_freak
(
    .CLK_VIDEO(clk_video),
    .CE_PIXEL(CE_PIXEL),
    .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH),
    .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE),
    .VIDEO_ARX(VIDEO_ARX),
    .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de_raw),
    .ARX(arx_in),
    .ARY(ary_in),
    .CROP_SIZE(12'd0),
    .CROP_OFF(5'd0),
    .SCALE(status[36:34])
);

wire vertical_profile = profile_valid &&
    ((profile_id == 3'd3) || (profile_id == 3'd5));
wire no_rotate = !vertical_profile || direct_video;

// MiSTer's standard screen_rotate path stores portrait frames in DDRAM for
// HDMI while retaining the native arcade timing on VGA.  The framebuffer
// conduit is a QSF-selected interface; keep non-MISTER_FB simulation tops
// self-contained until that framework contract is enabled.
`ifdef MISTER_FB
screen_rotate screen_rotate
(
    .CLK_VIDEO(clk_video), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
    .rotate_ccw(1'b0), .no_rotate(no_rotate), .flip(1'b0),
    .video_rotated(video_rotated),
    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
    .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL), .FB_LL(FB_LL),
    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD)
);

assign FB_FORCE_BLANK = 1'b0;
`else
assign video_rotated = 1'b0;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE, DDRAM_RD} = '0;
`endif
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
// USER_OUT is the only portable MiSTer user-conduit for board bookkeeping
// signals.  Expose the decoded SunA start LEDs, coin counter and lockout
// latches here; the low bit also retains a live core-ready indication.
assign USER_OUT = {pcb_coin_lockouts, pcb_coin_counters,
                   pcb_start_leds, core_ready};
assign pcb_start_leds = pcb_start_leds_core;
assign pcb_coin_counters = pcb_coin_counters_core;
assign pcb_coin_lockouts = pcb_coin_lockouts_core;
assign LED_USER = profile_valid ? frame_counter[25] : 1'b0;

endmodule
