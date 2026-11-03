module emu (`include "sys/emu_ports.vh");
    assign ADC_BUS = 'z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_TXD, UART_DTR} = '0;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'z;
    assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE,
            SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS,
            SDRAM_nCS} = 'z;
    assign DDRAM_CLK = clk_sys;
    assign DDRAM_RD = 1'b0;
    assign {VGA_F1, VGA_SCALER, VGA_DISABLE} = '0;
    assign {HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT} = '0;
    assign AUDIO_S = 1'b1;
    assign AUDIO_MIX = 2'b00;
    assign {LED_DISK, LED_POWER, BUTTONS} = '0;

    function automatic signed [4:0] decode_crt_size(input logic [4:0] index_value);
        case (index_value)
            5'd1: decode_crt_size =  5'sd1;
            5'd2: decode_crt_size =  5'sd2;
            5'd3: decode_crt_size = -5'sd2;
            5'd4: decode_crt_size = -5'sd1;
            default: decode_crt_size = 5'sd0;
        endcase
    endfunction

    function automatic signed [6:0] decode_crt_hposition(input logic [6:0] index_value);
        if (index_value <= 7'd15) decode_crt_hposition = $signed(index_value);
        else if (index_value <= 7'd31) decode_crt_hposition = index_value - 7'd32;
        else decode_crt_hposition = 7'sd0;
    endfunction

    function automatic signed [4:0] decode_crt_vposition(input logic [4:0] index_value);
        if (index_value <= 5'd15) decode_crt_vposition = $signed(index_value);
        else decode_crt_vposition = index_value - 5'd32;
    endfunction

    localparam CONF_STR = {
        "DAIKAIJU;;",
        // Layout follows HeavyUnit: Video Settings and Game Settings pages,
        // then the MRA DIP Switches page (MiSTer shows DIP only at top level).
        "P1,Video Settings;",
        "P1O[42:41],Aspect ratio,Original,4:3,Full Screen;",
        "H1P1O[13:12],Orientation,90 CCW,90 CW,Normal,180;",
        "H1P1O[17:15],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
        "P1-;",
        "P1O[54],CRT Adjust,Off,On;",
        "H4P1O[59:55],CRT H-Size,0,+1,+2,-2,-1;",
        "H4P1O[66:60],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H4P1O[71:67],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P2,Game Settings;",
        "P2O[20:19],Main CPU Speed,2x (12 MHz),Original (6 MHz),2.67x (16 MHz);",
        "P2O[30],OSD Pause,Off,On;",
        "DIP;",
        "-;",
        "R[0],Reset;",
        "J1,Fire,Secondary,Start 1,Start 2,Coin 1,Coin 2,Service Mode,Pause;",
        "v,0;"
    };

    wire [127:0] status;
    wire [1:0] buttons;
    wire [10:0] ps2_key;
    wire [21:0] gamma_bus;
    wire forced_scandoubler;
    wire direct_video;
    wire video_rotated;
    wire [31:0] joystick_0, joystick_1;
    wire ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd;
    wire [15:0] ioctl_index, ioctl_dout, ioctl_din;
    wire [26:0] ioctl_addr;
    wire ioctl_upload_req, hiscore_upload_want, hiscore_pause_req, hiscore_mem_write;
    wire [15:0] hiscore_mem_address, hiscore_cpu_address;
    wire [7:0] hiscore_mem_write_data, hiscore_mem_read_data;
    wire hiscore_cpu_write;
    wire [7:0] hiscore_cpu_write_data;
    wire [35:0] unused_hps_extension;
    assign unused_hps_extension[32]=1'b0;
    hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io(
        .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(unused_hps_extension), .gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler), .buttons(buttons),
        .direct_video(direct_video), .video_rotated(video_rotated),
        .joystick_0(joystick_0), .joystick_1(joystick_1),
        .status(status), .status_menumask({27'd0, !status[54], 2'b00, direct_video, 1'b0}), .ps2_key(ps2_key),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(1'b0),
        .ioctl_upload(ioctl_upload), .ioctl_rd(ioctl_rd), .ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(8'd8), .ioctl_din(ioctl_din)
    );

    wire clk_sys;
    wire pll_locked;
    pll pll(.refclk(CLK_50M), .rst(1'b0), .outclk_0(clk_sys), .locked(pll_locked));
    wire ce_pixel, ce_prepare;
    wire ce_main_6mhz, ce_osc_3mhz, ce_aux_3mhz;
    wire [8:0] h_count, v_count;
    wire hsync_n, vsync_n, active_video;
    daikaiju_clock_enables clock_enables (
        .clk_sys(clk_sys), .cpu_speed(status[20:19]), .ce_main_6mhz(ce_main_6mhz), .ce_osc_3mhz(ce_osc_3mhz)
    );
    daikaiju_video_timing timing(
        .clk_sys(clk_sys), .ce_pixel(ce_pixel), .ce_prepare(ce_prepare), .h_count(h_count), .v_count(v_count),
        .hsync_n(hsync_n), .vsync_n(vsync_n), .active_video(active_video)
    );

    // J1 Service is the arcade test/service switch (MAME "Service Mode", DSWA
    // bit 2 = SWA:3). Each press flips it and resets the game, because the
    // A74 firmware samples the switch at boot and then shows its test screen.
    // The state survives game resets and clears only on a core reload. The
    // MAME SERVICE1 input is a service *coin*, so it is deliberately unused.
    logic service_button_q = 1'b0, service_mode = 1'b0;
    logic [19:0] service_reset_cnt = 20'd0;
    always_ff @(posedge clk_sys) begin
        service_button_q <= joystick_0[10];
        if (RESET || !pll_locked) begin
            service_mode <= 1'b0;
            service_reset_cnt <= 20'd0;
        end else if (joystick_0[10] && !service_button_q) begin
            service_mode <= !service_mode;
            service_reset_cnt <= 20'hFFFFF;
        end else if (service_reset_cnt != 20'd0) begin
            service_reset_cnt <= service_reset_cnt - 20'd1;
        end
    end
    wire service_reset = (service_reset_cnt != 20'd0);

    // Raster and sync free-run through reset, ROM loading, pause and OSD.
    wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download | service_reset;
    wire signed [4:0] crt_hsize_request = decode_crt_size(status[59:55]);
    wire signed [6:0] crt_hposition_request = decode_crt_hposition(status[66:60]);
    wire signed [4:0] crt_vposition_request = decode_crt_vposition(status[71:67]);
    logic crt_enable_q = 1'b0;
    logic signed [4:0] crt_hsize_q = 5'sd0, crt_vposition_q = 5'sd0;
    logic signed [6:0] crt_hposition_q = 7'sd0;
    logic pause_button_q = 1'b0;
    logic pause_toggle = 1'b0;
    wire pause_request = status[30] || pause_toggle;
    wire main_pause_ack;

    // J1 Pause is button bit 11; the menu option also permits a persistent pause.
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            pause_button_q <= 1'b0;
            pause_toggle <= 1'b0;
            crt_enable_q <= 1'b0;
            crt_hsize_q <= 5'sd0;
            crt_hposition_q <= 7'sd0;
            crt_vposition_q <= 5'sd0;
        end else begin
            pause_button_q <= joystick_0[11];
            if (joystick_0[11] && !pause_button_q)
                pause_toggle <= !pause_toggle;
            if (ce_pixel && (h_count == 9'd0) && (v_count == 9'd240)) begin
                crt_enable_q <= status[54];
                crt_hsize_q <= crt_hsize_request;
                crt_hposition_q <= crt_hposition_request;
                crt_vposition_q <= crt_vposition_request;
            end
        end
    end

    wire [8:0] raw_display_x, raw_display_y, prefetch_y;
    wire raw_adjusted_active;
    logic [8:0] display_x, display_y;
    logic adjusted_active = 1'b0;
    daikaiju_video_geometry video_geometry (
        .hsize(crt_hsize_q), .hposition(crt_hposition_q),
        .vposition(crt_vposition_q), .adjust_enable(crt_enable_q),
        .h_counter(h_count), .v_counter(v_count),
        .display_x(raw_display_x), .display_y(raw_display_y),
        .display_valid(raw_adjusted_active), .prefetch_y(prefetch_y)
    );
    // Counters and frame-latched CRT controls are stable from phase 6 to 7.
    // Free-running preparation covers reset without moving prefetch timing.
    always_ff @(posedge clk_sys) if (ce_prepare) begin
        display_x <= raw_display_x;
        display_y <= raw_display_y;
        adjusted_active <= raw_adjusted_active;
    end
`ifdef SIMULATION
    always @(posedge clk_sys) if (ce_pixel && !reset) begin
        assert ({display_x,display_y,adjusted_active} ===
                {raw_display_x,raw_display_y,raw_adjusted_active})
            else $fatal(1,"prepared geometry changed sampled pixel");
    end
`endif

    daikaiju_ce_guard #(.MIN_SPACING(16)) pause_ce_guard (
        // Reset must clock the JT03 delay lines. Keep cooldown state across
        // reset so neither assertion nor release can shorten CE spacing.
        .clk_sys(clk_sys), .reset(1'b0), .enable(reset || !main_pause_ack),
        .ce_in(ce_osc_3mhz), .ce_out(ce_aux_3mhz)
    );
    wire [7:0] dip_a, dip_b;
    wire [7:0] dip_a_effective = dip_a & ~{5'd0, service_mode, 2'd0}; // active-low test switch
    wire [7:0] player1_inputs_n, player2_inputs_n;
    wire [7:0] starts_service, service_tilt;
    wire [1:0] coin_active = {joystick_0[9], joystick_0[8]};
    wire [7:0] sound_command, mcu_status, mcu_host_data, mcu_data_write_data;
    wire [7:0] mcu_data_out_unused;
    wire sound_command_pending, mcu_data_read, mcu_data_write;
    wire [2:0] rom_bank_debug;
    wire flip_debug;
    wire [7:0] work_address_debug;
    wire [15:0] cpu_address_debug;
    wire cpu_m1_n_debug;
    wire [13:0] video_scan_address;
    wire [7:0] video_scan_data;
    wire [1:0] mcu_flags_debug;
    wire [7:0] mcu_pa_debug, mcu_pb_debug;
    wire [3:0] mcu_pc_debug;
    wire [12:0] mcu_address_debug;
    wire [7:0] mcu_pa_input_debug;
    wire [3:0] mcu_pc_input_debug;
    wire mcu_host_irq_debug;
    wire irq_vblank = ce_pixel && (h_count == 9'd0) && (v_count == 9'd240);
    wire sound_command_ack;
    wire signed [15:0] sound_audio_sample;
    wire sound_audio_sample_valid;
    daikaiju_dip_switches dip_switches (
        .clk_sys(clk_sys), .ioctl_wr(ioctl_download && ioctl_wr),
        .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .dip_a(dip_a), .dip_b(dip_b)
    );

    assign player1_inputs_n = {2'b11, ~joystick_0[5], ~joystick_0[4],
                               ~joystick_0[3], ~joystick_0[2], ~joystick_0[0], ~joystick_0[1]};
    assign player2_inputs_n = {2'b11, ~joystick_1[5], ~joystick_1[4],
                               ~joystick_1[3], ~joystick_1[2], ~joystick_1[0], ~joystick_1[1]};
    assign starts_service = {2'b11, ~joystick_0[7], ~joystick_0[6], 4'hf};
    assign service_tilt = 8'hff; // SERVICE1 (service coin) and TILT unused

    daikaiju_main_board main_board (
        .clk_sys(clk_sys), .reset_n(~reset), .ce_6mhz(ce_main_6mhz),
        .pause_req(pause_request || hiscore_pause_req), .pause_ack(main_pause_ack),
        .irq_vblank(irq_vblank), .sound_command_ack(sound_command_ack),
        .mcu_data_in(mcu_host_data),
        // WIDE ioctl_addr is a byte offset (advanced by two per 16-bit beat).
        .rom_write(ioctl_download && ioctl_wr && (ioctl_index == 16'd0) && (ioctl_addr < 27'h18000)),
        .rom_write_address(ioctl_addr[16:0]), .rom_write_data(ioctl_dout),
        .hiscore_mem_address(hiscore_mem_address), .hiscore_mem_write(hiscore_mem_write),
        .hiscore_mem_write_data(hiscore_mem_write_data), .hiscore_mem_read_data(hiscore_mem_read_data),
        .hiscore_cpu_write(hiscore_cpu_write), .hiscore_cpu_address(hiscore_cpu_address),
        .hiscore_cpu_write_data(hiscore_cpu_write_data),
        .dip_a(dip_a_effective), .dip_b(dip_b), .player1(player1_inputs_n), .player2(player2_inputs_n),
        .starts_service(starts_service), .service_tilt(service_tilt), .mcu_status(mcu_status),
        .sound_command(sound_command), .sound_command_pending(sound_command_pending),
        .mcu_data_out(mcu_data_out_unused), .mcu_data_read(mcu_data_read),
        .mcu_data_write(mcu_data_write), .mcu_data_write_data(mcu_data_write_data),
        .video_scan_address(video_scan_address), .video_scan_data(video_scan_data),
        .work_address_debug(work_address_debug), .cpu_address_debug(cpu_address_debug),
        .cpu_m1_n_debug(cpu_m1_n_debug), .rom_bank_debug(rom_bank_debug), .flip_debug(flip_debug)
    );

    // Raise the hiscore save request only while the OSD is closed so the menu
    // saves once per OSD opening, never while navigating pages/directories.
    daikaiju_save_gate save_gate (
        .clk_sys(clk_sys), .reset(~pll_locked), .osd_open(OSD_STATUS),
        .want_save(hiscore_upload_want), .upload_active(ioctl_upload && (ioctl_index == 16'd8)),
        .upload_req(ioctl_upload_req)
    );

    daikaiju_hiscore hiscore (
        .clk_sys(clk_sys), .reset_game(reset),
        .nvram_download(ioctl_download && (ioctl_index == 16'd8)),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_upload(ioctl_upload && (ioctl_index == 16'd8)), .ioctl_din(ioctl_din),
        .ioctl_upload_req(hiscore_upload_want), .pause_req(hiscore_pause_req), .pause_ack(main_pause_ack),
        .mem_address(hiscore_mem_address), .mem_write(hiscore_mem_write),
        .mem_write_data(hiscore_mem_write_data), .mem_read_data(hiscore_mem_read_data),
        .cpu_write(hiscore_cpu_write), .cpu_address(hiscore_cpu_address),
        .cpu_write_data(hiscore_cpu_write_data), .ready()
    );

    daikaiju_mcu_board mcu_board (
        .clk_sys(clk_sys), .reset_n(~reset), .ce_osc_3mhz(ce_aux_3mhz),
        .host_data_write(mcu_data_write), .host_write_data(mcu_data_write_data),
        .host_data_read(mcu_data_read), .coin_active(coin_active),
        .rom_download_write(ioctl_download && ioctl_wr && (ioctl_index == 16'd2) && (ioctl_addr < 27'd2048)),
        .rom_download_address(ioctl_addr[10:0]), .rom_download_data(ioctl_dout),
        .host_data_read_value(mcu_host_data), .host_status(mcu_status),
        .host_flags_debug(mcu_flags_debug), .pa_input_debug(mcu_pa_input_debug),
        .pc_input_debug(mcu_pc_input_debug), .host_irq_debug(mcu_host_irq_debug),
        .mcu_address_debug(mcu_address_debug), .mcu_pa_debug(mcu_pa_debug),
        .mcu_pb_debug(mcu_pb_debug), .mcu_pc_debug(mcu_pc_debug)
    );

    daikaiju_sound_board sound_board (
        .clk_sys(clk_sys), .reset_n(~reset), .ce_3mhz(ce_aux_3mhz),
        .rom_download_write(ioctl_download && ioctl_wr && (ioctl_index == 16'd1) && (ioctl_addr < 27'd32768)),
        .rom_download_address({1'b0, ioctl_addr[14:1]}), .rom_download_data(ioctl_dout),
        .command_data(sound_command), .command_pending(sound_command_pending),
        .command_ack(sound_command_ack), .audio_sample(sound_audio_sample),
        .audio_sample_valid(sound_audio_sample_valid), .sound_pc(), .sound_bus_addr(),
        .sound_bus_dout(), .sound_bus_din(), .sound_m1_n(), .sound_mreq_n(),
        .sound_iorq_n(), .sound_rd_n(), .sound_wr_n(), .sound_irq_n(),
        .sound_nmi_n(), .sound_nmi_enabled()
    );

    wire [8:0] game_palette_index;
    // OSD order is CCW,CW,Normal,180 so the power-on default (0) is 90 CCW;
    // the video path keeps its original code: 0=CW, 1=Normal, 2=CCW, 3=180.
    logic [1:0] orientation;
    always_comb begin
        case (status[13:12])
            2'd0:    orientation = 2'd2;
            2'd1:    orientation = 2'd0;
            2'd2:    orientation = 2'd1;
            default: orientation = 2'd3;
        endcase
    end
    wire game_pixel_valid, palette_pixel_valid;
    wire [7:0] game_r, game_g, game_b;
    logic active_video_q, hsync_n_q, vsync_n_q;

    a74_video_renderer video_renderer (
        .clk_sys(clk_sys), .reset_n(~reset), .ce_pixel(ce_pixel),
        .h_counter(h_count), .v_counter(v_count),
        .display_x(display_x), .display_y(display_y), .display_valid(adjusted_active),
        .prefetch_y(prefetch_y), .flip_screen(flip_debug ^ (orientation == 2'd3)),
        .vram_data(video_scan_data), .vram_address(video_scan_address),
        .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wr(ioctl_download && ioctl_wr),
        .palette_index(game_palette_index), .pixel_valid(game_pixel_valid)
    );

    a74_palette_prom palette_prom (
        .clk_sys(clk_sys), .reset(reset), .ce_pixel(ce_pixel),
        .pixel_valid_in(game_pixel_valid), .palette_index(game_palette_index),
        .ioctl_wr(ioctl_download && ioctl_wr), .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .red(game_r), .green(game_g), .blue(game_b),
        .pixel_valid_out(palette_pixel_valid)
    );

    // The PROM lookup registers on the same CE edge as the raster metadata.
    always_ff @(posedge clk_sys) begin
        if (ce_pixel) begin
            active_video_q <= !reset && adjusted_active;
            hsync_n_q <= hsync_n;
            vsync_n_q <= vsync_n;
        end
    end

    wire game_video_active = active_video_q && palette_pixel_valid;
    logic hblank_q, vblank_q;
    always_ff @(posedge clk_sys) begin
        if (ce_pixel) begin
            // Horizontal blank remains active during every line, including
            // vertical blank, so the video mixer samples VBlank at line start.
            hblank_q <= (h_count >= 9'd256);
            vblank_q <= (v_count < 9'd16) || (v_count >= 9'd240);
        end
    end

    wire rotate_request = (orientation == 2'd0) || (orientation == 2'd2);
    wire no_rotate = direct_video || (orientation == 2'd1) || (orientation == 2'd3);
    wire rotate_ccw = orientation == 2'd2;
    logic [2:0] video_fx;
    always_comb begin
        case (status[17:15])
            3'd1: video_fx = 3'd2; // arcade_video reserves fx=1 for HQ2x.
            3'd2: video_fx = 3'd3;
            3'd3: video_fx = 3'd4;
            default: video_fx = 3'd0;
        endcase
    end
    wire [7:0] std_r, std_g, std_b;
    wire std_hs, std_vs, std_de;
    wire [1:0] std_sl;
    wire [28:0] rotate_ddram_addr;
    wire [63:0] rotate_ddram_din;
    wire [7:0] rotate_ddram_be, rotate_ddram_burst;
    wire rotate_ddram_we, rotate_ddram_rd;
    wire [6:0] rotate_fifo_occupancy;
    wire rotate_fifo_overflow;

    daikaiju_arcade_video #(.WIDTH(256), .DW(24), .GAMMA(1)) video_mixer (
        .clk_video(clk_sys), .ce_pix(ce_pixel), .RGB_in({game_r, game_g, game_b}),
        .HBlank(hblank_q), .VBlank(vblank_q), .HSync(hsync_n_q), .VSync(vsync_n_q),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(std_r), .VGA_G(std_g), .VGA_B(std_b), .VGA_HS(std_hs), .VGA_VS(std_vs),
        .VGA_DE(std_de), .VGA_SL(std_sl),
        .fx(direct_video ? 3'd0 : video_fx),
        .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
    );

    daikaiju_screen_rotate rotate_video (
        .RESET(reset),
        .QUEUE_IDLE((rotate_fifo_occupancy == 0) && !rotate_ddram_we),
        .QUEUE_FAULT(rotate_fifo_overflow),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(std_r), .VGA_G(std_g), .VGA_B(std_b),
        .VGA_HS(std_hs), .VGA_VS(std_vs), .VGA_DE(std_de),
        .rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(1'b0),
        .video_rotated(video_rotated),
        .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
        .DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(rotate_ddram_burst),
        .DDRAM_ADDR(rotate_ddram_addr), .DDRAM_DIN(rotate_ddram_din),
        .DDRAM_BE(rotate_ddram_be), .DDRAM_WE(rotate_ddram_we), .DDRAM_RD(rotate_ddram_rd)
    );

    daikaiju_ddram_write_fifo #(.DEPTH(64)) rotate_write_queue (
        .clk(CLK_VIDEO), .reset(reset), .in_valid(rotate_ddram_we),
        .in_address(rotate_ddram_addr), .in_data(rotate_ddram_din),
        .in_byteenable(rotate_ddram_be), .in_burstcount(rotate_ddram_burst),
        .ddram_busy(DDRAM_BUSY), .ddram_address(DDRAM_ADDR), .ddram_data(DDRAM_DIN),
        .ddram_byteenable(DDRAM_BE), .ddram_burstcount(DDRAM_BURSTCNT),
        .ddram_write(DDRAM_WE), .overflow(rotate_fifo_overflow), .occupancy(rotate_fifo_occupancy)
    );

    assign VGA_SL = std_sl;
    // Aspect ratio: 0=Original (8:7 native raster), 1=4:3, 2/3=Full Screen.
    assign VIDEO_ARX = (status[42:41] == 2'd0) ? 13'd8 : (status[42:41] == 2'd1) ? 13'd4 : 13'd0;
    assign VIDEO_ARY = (status[42:41] == 2'd0) ? 13'd7 : (status[42:41] == 2'd1) ? 13'd3 : 13'd0;
    assign VGA_R = std_r;
    assign VGA_G = std_g;
    assign VGA_B = std_b;
    assign VGA_HS = std_hs;
    assign VGA_VS = std_vs;
    assign VGA_DE = std_de;
    assign FB_FORCE_BLANK = 1'b0;
    assign AUDIO_L = sound_audio_sample;
    assign AUDIO_R = sound_audio_sample;
    assign LED_USER = rotate_fifo_overflow;
endmodule
