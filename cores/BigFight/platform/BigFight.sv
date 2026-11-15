//============================================================================
//  Big Fight (Tatsumi ABA-011/ABA-012) MiSTer top level.
//
//  Derived from Template_MiSTer 5dda37366d02b04b8448da7b322235c1831af811
//  (GPL-2.0-or-later notice/license retained in platform/Template.sv, LICENSE).
//
//  Clocks (clock_plan.json): clk_sys == CLK_VIDEO = PLL outclk_0 50MHz,
//  pixel CE = integer /8 (6.25MHz), raster 400x261 (59.8659Hz).
//  SDRAM controller runs on clk_sys too (1x, CL2); SDRAM_CLK is the inverted
//  clk_sys forwarded through altddio_out.
//============================================================================
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_TXD, UART_DTR} = '0;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
`ifndef MISTER_FB
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
`endif
    assign VGA_F1 = 0;
    assign VGA_SCALER = 0;
    assign VGA_DISABLE = 0;
    assign HDMI_FREEZE = 0;
    assign HDMI_BLACKOUT = 0;
    assign HDMI_BOB_DEINT = 0;
    assign AUDIO_MIX = 0;
    assign LED_DISK = 0;
    assign LED_POWER = 0;
    assign BUTTONS = 0;

    `include "build_id.v"
    localparam CONF_STR = {
        "BigFight;;",
        "-;",
        "P1,Video Settings;",
        "P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        "P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
        "P1O[7:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
        "P1H0O[19:18],HDMI Rotation,Off,CW,CCW,180;",
        "P1O[22:20],CRT H-Size,Normal,+8,+16,-16,-8;",
        "P1-;",
        "P1O[11:8],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P1O[15:12],CRT V-Position,0,+1,+2,-1,-2,-3,-4,-5,-6,-7,-8,-9,-10,-11,-12;",
        "-;",
        "DIP;",
        "P2,Game Settings;",
        "P2O[16],Pause when OSD open,Off,On;",
        "P2O[17],Autosave Scores,Off,On;",
        "-;",
        "R[0],Reset;",
        "J1,Attack,Jump,Start,Coin,Service,Pause;",
        "jn,A,B,Start,Select,R,L;",
        "V,v",`BUILD_DATE
    };

    // ------------------------------------------------------------------
    // Clocks and resets
    // ------------------------------------------------------------------
    wire clk_sys, pll_locked;
    bigfight_pll pll (
        .refclk(CLK_50M), .rst(1'b0),
        .outclk_0(clk_sys), .locked(pll_locked)
    );
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [1:0] lock_sys = 2'b00;
    always @(posedge clk_sys) lock_sys <= {lock_sys[0], pll_locked};
    wire sys_reset = !lock_sys[1];
    // SDRAM controller init follows PLL lock only (never core/OSD reset).
    wire mem_init = sys_reset;

    // ------------------------------------------------------------------
    // HPS
    // ------------------------------------------------------------------
    wire [127:0] status;
    wire direct_video;
    wire  [1:0] buttons;
    wire        forced_scandoubler;
    wire [21:0] gamma_bus;
    wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
    wire        ioctl_download, ioctl_wr, ioctl_wait, rom_ioctl_wait, score_ioctl_wait;
    wire        ioctl_upload, score_upload_request;
    wire [15:0] score_upload_data;
    wire [15:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_dout;

    // MRA profile byte at index 1; index 0 remains the identical ROM transport.
    reg [7:0] core_mod = 0;
    reg rom_download_q = 0;
    wire profile_download = ioctl_download && ioctl_index == 16'd1;
    always @(posedge clk_sys) begin
        rom_download_q <= ioctl_download && ioctl_index == 0;
        if (sys_reset) core_mod <= 0;
        else if (ioctl_download && ioctl_index == 0 && !rom_download_q)
            core_mod <= 0;
        else if (profile_download && ioctl_wr && ioctl_addr == 0)
            core_mod <= ioctl_dout[7:0];
    end
    hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
        .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(), .gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler), .buttons(buttons), .status(status),
        .status_menumask({15'd0,direct_video}), .direct_video(direct_video),
        .joystick_0(joystick_0), .joystick_1(joystick_1),
        .joystick_2(joystick_2), .joystick_3(joystick_3),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
        .ioctl_upload(ioctl_upload), .ioctl_upload_req(score_upload_request),
        .ioctl_upload_index(8'd4), .ioctl_din(score_upload_data)
    );

    // DIP bytes (index 254): DSW1, DSW2, DSW3. Defaults are MAME 0.289's.
    reg [7:0] dsw1 = 8'hff, dsw2 = 8'h7f, dsw3 = 8'h0d;
    always @(posedge clk_sys) begin
        if (ioctl_download && ioctl_wr && ioctl_index[7:0] == 8'd254) begin
            if (ioctl_addr == 27'd0) begin dsw1 <= ioctl_dout[7:0]; dsw2 <= ioctl_dout[15:8]; end
            if (ioctl_addr == 27'd2) dsw3 <= ioctl_dout[7:0];
        end
    end

    // ------------------------------------------------------------------
    // Inputs (MAME bigfight ports, active low).
    // MiSTer joystick bits: 0 R,1 L,2 D,3 U,4 Attack,5 Jump,6 Start,7 Coin,8 Service.
    // P port: 0 Start,1 BUTTON3 (no game function; held released),2 Jump,3 Attack,
    //         4 Right,5 Left,6 Down,7 Up. Evidence: verification/mame/button_functions.
    // ------------------------------------------------------------------
    function automatic [7:0] player_port(input [31:0] j);
        player_port = ~{j[3], j[2], j[1], j[0], j[4], j[5], 1'b0, j[6]};
    endfunction
    wire [7:0] p1_n = player_port(joystick_0);
    wire [7:0] p2_n = player_port(joystick_1);
    wire [7:0] p3_n = player_port(joystick_2);
    wire [7:0] p4_n = player_port(joystick_3);
    wire [7:0] service_n = ~{joystick_3[8], joystick_2[8], joystick_1[8], joystick_0[8],
                             joystick_3[7], joystick_2[7], joystick_1[7], joystick_0[7]};

    // ------------------------------------------------------------------
    // Memory, loader and boot sequencer
    // ------------------------------------------------------------------
    wire game_cold_start, game_reset, game_load_mode, rom_loaded, game_running;
    wire load_valid, load_ready;
    wire [2:0] load_bank;
    wire [14:0] load_word_address;
    wire [15:0] load_data;
    wire rom_reset;
    wire backend_req_valid, backend_req_ready, backend_rsp_valid, backend_rsp_ready;
    wire [25:0] backend_req_address;
    wire [63:0] backend_rsp_data;
    wire memory_error;

    bigfight_mister_memory memory (
        .clk_sys(clk_sys), .clk_mem(clk_sys), .mem_init(mem_init), .sys_reset(sys_reset),
        .user_reset(RESET | status[0] | buttons[1] | profile_download),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(rom_ioctl_wait),
        .game_cold_start(game_cold_start), .game_reset(game_reset), .game_load_mode(game_load_mode),
        .load_valid(load_valid), .load_bank(load_bank), .load_word_address(load_word_address),
        .load_data(load_data), .load_ready(load_ready),
        .rom_loaded(rom_loaded), .game_running(game_running),
        .rom_reset_i(rom_reset),
        .backend_req_valid(backend_req_valid), .backend_req_ready(backend_req_ready),
        .backend_req_address(backend_req_address), .backend_rsp_valid(backend_rsp_valid),
        .backend_rsp_ready(backend_rsp_ready), .backend_rsp_data(backend_rsp_data),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .protocol_error(memory_error)
    );

    // ------------------------------------------------------------------
    // Game
    // ------------------------------------------------------------------
    wire        video_ce, video_hblank, video_vblank, video_active;
    wire  [8:0] raster_x, raster_y;
    wire [23:0] rgb;
    wire signed [17:0] audio_left, audio_right;
    wire        audio_valid;
    wire        game_fault, game_deadline;

    wire pause_ack, score_pause, score_access, score_write;
    wire [15:0] score_address;
    wire [7:0] score_wdata, score_rdata;
    reg pause_button_q = 0, user_pause = 0;
    wire pause_button = joystick_0[9] | joystick_1[9] | joystick_2[9] | joystick_3[9];
    always @(posedge clk_sys) begin
        pause_button_q <= pause_button;
        if (game_reset) user_pause <= 0;
        else if (pause_button && !pause_button_q) user_pause <= !user_pause;
    end
    wire pause_request = user_pause | (status[16] && OSD_STATUS) | score_pause;
    assign ioctl_wait = rom_ioctl_wait | score_ioctl_wait;
    bigfight_score_io scores(
        .cyclwarr_i(core_mod[0]),
        .clk(clk_sys), .reset(game_reset), .hard_reset(sys_reset | profile_download), .paused(pause_ack),
        .autosave(status[17]), .osd_open(OSD_STATUS),
        .download(ioctl_download), .upload(ioctl_upload), .wr(ioctl_wr),
        .address(ioctl_addr), .index(ioctl_index), .data(ioctl_dout),
        .upload_data(score_upload_data), .wait_hps(score_ioctl_wait),
        .upload_request(score_upload_request), .pause_request(score_pause),
        .configured(), .ready(), .access_ram(score_access), .write_ram(score_write),
        .ram_address(score_address), .ram_data(score_wdata), .ram_q(score_rdata)
    );

    bigfight_game_rom game (.cyclwarr_i(core_mod[0]),
        .pause_req(pause_request), .pause_ack(pause_ack),
        .hs_access(score_access), .hs_write(score_write), .hs_address(score_address),
        .hs_wdata(score_wdata), .hs_rdata(score_rdata),
        .clk_sys(clk_sys), .reset(game_reset), .cold_start(game_cold_start),
        .service_i(service_n), .p1_i(p1_n), .p2_i(p2_n), .p3_i(p3_n), .p4_i(p4_n),
        .dsw1_i(dsw1), .dsw2_i(dsw2), .dsw3_i(dsw3),
        .mem_valid(), .mem_req(), .mem_wr(), .mem_cpu(), .mem_uds_n(), .mem_lds_n(),
        .mem_address(), .mem_din(), .mem_ready(), .mem_dout(),
        .ce_pixel(), .hblank(), .vblank(), .line_start(), .frame_start(), .vblank_start(),
        .x(), .y(), .video_config(), .tile_bank(), .mixing_control(), .crtc_regs(),
        .sound_command(), .sound_command_strobe(), .slave_halt(), .coin_outputs(),
        .main_unmapped(), .sub_unmapped(), .main_addr(), .sub_addr(), .main_as_n(), .sub_as_n(),
        .main_fc(), .sub_fc(), .main_iack(), .sub_iack(),
        .trace_req(), .trace_cpu(), .trace_wr(), .trace_uds_n(), .trace_lds_n(),
        .trace_address(), .trace_din(), .trace_dout(),
        .command_ready_o(), .command_pending_o(), .command_overwrite_o(),
        .audio_rom_req_o(), .audio_rom_addr_o(), .audio_rom_ready_i(), .audio_rom_valid_i(), .audio_rom_data_i(),
        .oki_rom_req_o(), .oki_rom_addr_o(), .oki_rom_ready_i(), .oki_rom_valid_i(), .oki_rom_data_i(),
        .audio_left_o(audio_left), .audio_right_o(audio_right), .audio_sample_valid_o(audio_valid),
        .z80_wait_ce_count_o(), .audio_rom_wait_ce_count_o(), .oki_missed_ce1_count_o(),
        .z80_wait_seen_o(), .oki_timing_degraded_o(), .ce4_tick_o(), .ym_ce2_tick_o(), .oki_ce1_tick_o(),
        .load_mode(game_load_mode), .rom_reset_o(rom_reset),
        .rom_req(), .rom_master(), .rom_ready(), .rom_word_address(), .rom_rsp_valid(),
        .rom_rsp_ready(), .rom_rsp_data(),
        .load_valid(load_valid), .load_bank(load_bank), .load_word_address(load_word_address),
        .load_data(load_data), .load_uds_n(1'b0), .load_lds_n(1'b0), .load_ready(load_ready),
        .line_bank_valid_o(), .frame_done_valid_o(), .frame_done_id_o(),
        .tile_gfx_req_o(), .tile_gfx_ready_i(), .tile_gfx_row_addr_o(), .tile_gfx_rsp_valid_i(),
        .tile_gfx_rsp_ready_o(), .tile_gfx_rsp_data_i(),
        .tile_clut_req_o(), .tile_clut_ready_i(), .tile_clut_row_addr_o(), .tile_clut_rsp_valid_i(),
        .tile_clut_rsp_ready_o(), .tile_clut_rsp_data_i(),
        .sprite_rom_req_o(), .sprite_rom_ready_i(), .sprite_rom_bank_o(), .sprite_rom_byte_addr_o(),
        .sprite_rom_valid_i(), .sprite_rom_data_i(),
        .sprite_clut_req_o(), .sprite_clut_ready_i(), .sprite_clut_color_o(), .sprite_clut_valid_i(),
        .sprite_clut_bytes_i(),
        .line_done_collect_cycles_o(), .line_bank_y0_o(), .line_bank_y1_o(), .line_bank_late_o(),
        .video_deadline_miss_o(), .video_protocol_fault_o(), .frame_protocol_fault_o(),
        .frame_deadline_miss_o(), .frame_prepared_count_o(), .frame_late_selection_count_o(),
        .frame_missed_window_count_o(),
        .video_ce_o(video_ce), .raster_x_o(raster_x), .raster_y_o(raster_y),
        .video_hblank_o(video_hblank), .video_vblank_o(video_vblank), .video_active_o(video_active),
        .rgb_o(rgb),
        .scanout_deadline_miss_o(), .scanout_deadline_miss_count_o(), .scanout_protocol_fault_o(),
        .scanout_protocol_fault_count_o(), .last_line_cycles_o(), .last_line_late_o(),
        .max_pixel_latency_o(), .render_frame_id_o(), .render_sprite_control_o(), .frame_epoch_valid_o(),
        .game_protocol_fault_o(game_fault), .game_deadline_miss_o(game_deadline),
        .rom_backend_req_o(backend_req_valid), .rom_backend_ready_i(backend_req_ready),
        .rom_backend_byte_address_o(backend_req_address), .rom_backend_rsp_valid_i(backend_rsp_valid),
        .rom_backend_rsp_ready_o(backend_rsp_ready), .rom_backend_rsp_data_i(backend_rsp_data)
    );

    // ------------------------------------------------------------------
    // Video: 400x261 raster, visible 320x240. HD6445 programs a 40-pixel
    // HSYNC and a 7-line VSYNC (R3=0x75) at row 242 (R7/R27); see
    // docs/PCB_SYNC_REVIEW.md. HS is placed in horizontal blanking with
    // a 16-pixel front porch; electrical sync phase is unmeasured.
    // CRT position options move only the sync windows (fixed widths/period).
    // ------------------------------------------------------------------
    wire signed [4:0] h_adj = $signed({status[11], status[11:8]});
    wire        [3:0] v_sel = status[15:12];
    // VSYNC must stay inside the 21 blanking lines (240..260): start 240..254.
    wire signed [4:0] v_adj = (v_sel <= 4'd2) ? $signed({1'b0, v_sel}) :
                              (v_sel == 4'd15) ? 5'sd0 : -$signed({1'b0, v_sel - 4'd2});
    reg  [8:0] hs_start, vs_start;
    wire [8:0] geometry_width;
    always @(posedge clk_sys) begin
        hs_start <= ((9'd336 - 9'($signed(h_adj))) < geometry_width+9'd8) ?
                    geometry_width+9'd8 : 9'd336 - 9'($signed(h_adj));
        // Same inferred HD6445 row formula: R7*8 + R27 (SY enabled).
        vs_start <= (core_mod[0] ? 9'd252 : 9'd242) - 9'($signed(v_adj));
    end
    reg        ce_out, hs_out, vs_out, hb_out, vb_out;
    reg [8:0] output_x, output_y;
    reg [23:0] rgb_out;
    always @(posedge clk_sys) begin
        ce_out <= video_ce;
        if (video_ce) begin
            output_x <= raster_x; output_y <= raster_y;
            hs_out <= (raster_x >= hs_start) && (raster_x < hs_start + 9'd40);
            vs_out <= (raster_y >= vs_start) && (raster_y < vs_start + 9'd7);
            hb_out <= video_hblank;
            vb_out <= video_vblank;
            rgb_out <= video_active ? rgb : 24'd0;
        end
    end

    wire [2:0] scale = status[7:6];
    wire [1:0] ar = status[122:121];
    wire       vga_de_raw;
    wire geometry_ce,geometry_hs,geometry_vs,geometry_hb,geometry_vb;
    wire [23:0] geometry_rgb;
    bigfight_crt_size geometry(
        .clk(clk_sys),.reset(sys_reset),.ce_in(ce_out),.x(output_x),.y(output_y),
        .size_option(status[22:20]),.rgb_in(rgb_out),
        .hs_in(hs_out),.vs_in(vs_out),.hb_in(hb_out),.vb_in(vb_out),
        .ce_out(geometry_ce),.hs_out(geometry_hs),.vs_out(geometry_vs),
        .hb_out(geometry_hb),.vb_out(geometry_vb),.rgb_out(geometry_rgb),
        .active_width(geometry_width)
    );
    arcade_video #(.WIDTH(320), .DW(24)) arcade_video (
        .clk_video(clk_sys), .ce_pix(geometry_ce),
        .RGB_in(geometry_rgb), .HBlank(geometry_hb), .VBlank(geometry_vb), .HSync(geometry_hs), .VSync(geometry_vs),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .VGA_DE(vga_de_raw), .VGA_SL(VGA_SL),
        .fx(status[5:3]), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
    );
    wire [12:0] native_arx,native_ary,rotated_arx,rotated_ary;
    video_freak video_freak (
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
        .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
        .VGA_DE(VGA_DE), .VIDEO_ARX(native_arx), .VIDEO_ARY(native_ary),
        .VGA_DE_IN(vga_de_raw),
        .ARX((!ar) ? (rotated_90 ? 12'd3 : 12'd4) : {10'd0, ar - 2'd1}),
        .ARY((!ar) ? (rotated_90 ? 12'd4 : 12'd3) : 12'd0),
        .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE(rotated_90 ? 3'd0 : scale)
    );
`ifdef MISTER_FB
    video_scale_int rotated_scale(
        .CLK_VIDEO(CLK_VIDEO),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),.SCALE(scale),
        .hsize(FB_WIDTH),.vsize(FB_HEIGHT),
        .arx_i(!ar ? 12'd3 : {10'd0,ar-2'd1}),.ary_i(!ar ? 12'd4 : 12'd0),
        .arx_o(rotated_arx),.ary_o(rotated_ary)
    );
    assign VIDEO_ARX=rotated_90 ? rotated_arx : native_arx;
    assign VIDEO_ARY=rotated_90 ? rotated_ary : native_ary;
`else
    assign VIDEO_ARX=native_arx;
    assign VIDEO_ARY=native_ary;
`endif

    // ------------------------------------------------------------------
    // HDMI framebuffer transport retains each tuple through DDRAM_BUSY.
    wire [1:0] rotation = direct_video ? 2'd0 : status[19:18];
`ifdef MISTER_FB
    wire rotated_90 = FB_EN && FB_WIDTH < FB_HEIGHT;
`else
    wire rotated_90 = 0;
`endif
`ifdef MISTER_FB
    reg [1:0] rotation_q;
    always @(posedge clk_sys) if (sys_reset || (video_ce && raster_x==0 && raster_y==250))
        rotation_q <= sys_reset ? 2'd0 : rotation;
    bigfight_screen_rotate rotate(
        .CLK_VIDEO(CLK_VIDEO), .reset(sys_reset || rotation_q != rotation),
        .CE_PIXEL(CE_PIXEL), .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
        .rotate_ccw(rotation_q==2), .no_rotate(rotation_q==0 || rotation_q==3),
        .flip(rotation_q==3), .video_rotated(),
        .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
        .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
        .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
        .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD)
    );
    assign FB_FORCE_BLANK = 0;
`endif

    // Audio: signed18 board mix (YM 0.45 per side + OKI 0.75 centre), held
    // per sample and saturated to signed16 at the platform boundary.
    // ------------------------------------------------------------------
    function automatic [15:0] sat16(input signed [17:0] v);
        sat16 = (v > 18'sd32767) ? 16'h7fff : (v < -18'sd32768) ? 16'h8000 : v[15:0];
    endfunction
    reg [15:0] audio_l_q, audio_r_q;
    always @(posedge clk_sys) begin
        if (!game_running) begin audio_l_q <= 0; audio_r_q <= 0; end
        else if (audio_valid) begin audio_l_q <= sat16(audio_left); audio_r_q <= sat16(audio_right); end
    end
    assign AUDIO_L = audio_l_q;
    assign AUDIO_R = audio_r_q;
    assign AUDIO_S = 1'b1;

    // LED: loader activity or any latched game/memory fault.
    reg fault_seen;
    always @(posedge clk_sys)
        if (sys_reset || !game_running) fault_seen <= 1'b0;
        else if (game_fault || game_deadline || memory_error) fault_seen <= 1'b1;
    assign LED_USER = ioctl_download | fault_seen;
endmodule
