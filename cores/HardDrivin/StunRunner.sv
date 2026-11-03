// S.T.U.N. Runner top for the MiSTer framework (Hard Drivin' MultiSync
// board without MSP, ADSP board, JSA II sound).
module emu (
  `include "sys/emu_ports.vh"
);
  assign ADC_BUS = 'Z;
  assign USER_OUT = '1;
  assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
  assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

  assign VGA_F1 = 1'b0;
  assign VGA_SCALER = 1'b0;
  assign VGA_DISABLE = 1'b0;
  assign HDMI_FREEZE = 1'b0;
  assign HDMI_BLACKOUT = 1'b0;
  assign HDMI_BOB_DEINT = 1'b0;
  // JSA II output is mono.
  logic signed [15:0] sound_audio;
  assign AUDIO_S = 1'b1;
  assign AUDIO_L = sound_audio;
  assign AUDIO_R = sound_audio;
  assign AUDIO_MIX = 2'b00;
  assign LED_DISK = 2'b00;
  assign LED_POWER = 2'b00;
  assign BUTTONS = 2'b00;
  wire [127:0] status;

  // Video presentation: aspect (4:3 cabinet, full screen or user ARCs),
  // normal / integer / HD-integer scaling and scandoubler effects. HDMI,
  // analog VGA/CRT (15 kHz native with scandoubler off), direct video and
  // RetroTINK-4K over direct video use the stock framework paths.
  localparam CONF_STR = {
    "StunRunner;;",
    "-;",
    "DIP;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:4],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
    "O[8:6],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "O[3],Service mode (self-test),Off,On;",
    "-;",
    "O[10:9],Spinner speed,Normal,Fast,Faster,Slow;",
    "O[11],Invert steering,Off,On;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "J1,Fire L,Fire R,Start/Shockwave,Coin;",
    "jn,A,B,Start,Select;",
    "V,v1.0"
  };

  wire [1:0] buttons;
  wire ioctl_download;
  wire ioctl_upload, ioctl_rd;
  wire forced_scandoubler;
  wire [21:0] gamma_bus;
  wire [31:0] joystick_0;
  wire [15:0] joystick_l_analog_0;
  wire [8:0]  spinner_0;
  wire [7:0]  paddle_0;
  wire        ioctl_wr;
  wire [24:0] ioctl_addr;
  wire [7:0]  ioctl_dout;
  wire [15:0] ioctl_index;
  wire        nvram_ioctl_wait;
  wire [7:0]  nvram_ioctl_din;
  wire        nvram_save_req;

  hps_io #(.CONF_STR(CONF_STR)) u_hps_io (
    .clk_sys(CLK_50M), .HPS_BUS(HPS_BUS), .EXT_BUS(),
    .gamma_bus(gamma_bus), .forced_scandoubler(forced_scandoubler),
    .buttons(buttons), .status(status), .status_menumask(16'd0),
    .joystick_0(joystick_0), .joystick_l_analog_0(joystick_l_analog_0),
    .spinner_0(spinner_0), .paddle_0(paddle_0),
    .ioctl_download(ioctl_download), .ioctl_wait(nvram_ioctl_wait),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_upload(ioctl_upload), .ioctl_upload_req(nvram_save_req),
    .ioctl_upload_index(8'd2), .ioctl_din(nvram_ioctl_din), .ioctl_rd(ioctl_rd)
  );

  // ---- controls (MAME stunrun) ------------------------------------------
  // MRA buttons (joystick_0 bits 4..7): Fire L, Fire R (twin handlebar
  // triggers), Start/Shockwave, Coin. 0xa80000: bit 0 BUTTON1, bit 1
  // BUTTON2, bit 2 START1 (active low). Coins reach both the 68010 switch
  // port and the JSA II coin inputs, as in MAME.
  wire [31:0] joy = joystick_0;
  wire btn_fire    = joy[4];
  wire btn_fire_r  = joy[5];
  wire btn_start   = joy[6];
  wire btn_coin    = joy[7];
  wire service_mode = status[3];

  // Analog stick: MiSTer signed -127..127 becomes 0x01..0xff around 0x80;
  // the far end is pushed to 0x00 so both locks are reachable.
  function automatic [7:0] stick_to_adc(input [7:0] raw_signed);
    logic [7:0] u;
    begin
      u = raw_signed ^ 8'h80;
      stick_to_adc = (u <= 8'h01) ? 8'h00 : u;
    end
  endfunction
  wire [7:0] stick_x = stick_to_adc(joystick_l_analog_0[7:0]);
  wire [7:0] stick_y = stick_to_adc(joystick_l_analog_0[15:8]);

  // D-pad: digital steering (left/right) and pitch (up/down) on the same
  // ADC channels. Held: ramp to the lock in about 0.25 s (128 steps of
  // 1.95 ms); released: ramp back to centre. While a D-pad axis is held or
  // still returning, it overrides the stick on that axis.
  localparam int unsigned RAMP_CLOCKS = 97_656;   // 50 MHz / 512 Hz
  logic [16:0] ramp_div_q = '0;
  logic [7:0]  pad_x_q = 8'h80, pad_y_q = 8'h80;
  wire ramp_tick = (ramp_div_q == 17'(RAMP_CLOCKS - 1));
  function automatic [7:0] ramp(input [7:0] v, input dec, input inc);
    ramp = (dec && !inc) ? ((v > 8'h00) ? v - 8'd1 : v)
         : (inc && !dec) ? ((v < 8'hff) ? v + 8'd1 : v)
         : (v > 8'h80) ? v - 8'd1 : (v < 8'h80) ? v + 8'd1 : v;
  endfunction
  always_ff @(posedge CLK_50M) begin
    ramp_div_q <= ramp_tick ? 17'd0 : ramp_div_q + 17'd1;
    if (ramp_tick) begin
      pad_x_q <= ramp(pad_x_q, joy[1], joy[0]);   // left, right
      pad_y_q <= ramp(pad_y_q, joy[3], joy[2]);   // up, down
    end
  end
  // Steering (X) sources, most recently moved wins:
  //   0 analog stick / USB wheel axis, 1 paddle (absolute 0..255),
  //   2 spinner (relative, integrated into a handlebar position),
  //   3 D-pad ramp.
  // Per the shared lesson, the D-pad only takes X while the stick rests in
  // its deadzone (some pad maps raise the D-pad bits with the stick).
  wire stick_x_moved = (stick_x > 8'h90) || (stick_x < 8'h70);
  wire pad_y_active = joy[2] || joy[3] || (pad_y_q != 8'h80);
  logic [1:0] steer_src_q = 2'd0;
  logic [7:0] paddle_last_q = 8'h80;
  logic       paddle_init_q = 1'b0;
  logic [7:0] stick_x_last_q = 8'h80;
  logic       spin_toggle_meta_q = 1'b0;
  logic       spin_toggle_sync_q = 1'b0;
  logic       spin_toggle_seen_q = 1'b0;
  logic [7:0] spin_pos_q = 8'h80;
  logic signed [14:0] spin_pending_q = 15'sd0; // half-ADC-count units
  logic [13:0] spin_rate_div_q = 14'd0;
  logic [7:0] steer_x_raw;
  always_comb begin
    unique case (steer_src_q)
      2'd1:    steer_x_raw = paddle_0;
      2'd2:    steer_x_raw = spin_pos_q;
      2'd3:    steer_x_raw = pad_x_q;
      default: steer_x_raw = stick_x;
    endcase
  end
  // Follow the delta queue and fixed-rate drain in Ace9921's Arkanoid MiSTer
  // top level. Stun Runner reads steering as an 8-bit ADC value, so each
  // consumed step moves that value instead of advancing a quadrature phase.
  wire signed [10:0] spin_d = $signed({{3{spinner_0[7]}}, spinner_0[7:0]});
  logic signed [10:0] spin_delta_units;
  always_comb begin
    unique case (status[10:9])
      2'd1:    spin_delta_units = spin_d <<< 2; // x2, in half-counts
      2'd2:    spin_delta_units = spin_d <<< 3; // x4, in half-counts
      2'd3:    spin_delta_units = spin_d;        // x1/2, in half-counts
      default: spin_delta_units = spin_d <<< 1; // x1, in half-counts
    endcase
  end
  wire       spin_event = paddle_init_q && (spin_toggle_sync_q != spin_toggle_seen_q);
  wire       spin_tick = (spin_rate_div_q == 14'd12499); // 4 kHz at 50 MHz
  wire       stick_x_changed = (stick_x != stick_x_last_q) &&
                               (stick_x_moved || (stick_x_last_q > 8'h90) ||
                                                 (stick_x_last_q < 8'h70));
  wire signed [15:0] spin_pending_plus_delta = $signed(spin_pending_q) +
                                                $signed(spin_delta_units);
  wire [7:0] paddle_diff = (paddle_0 > paddle_last_q) ? paddle_0 - paddle_last_q
                                                       : paddle_last_q - paddle_0;
  always_ff @(posedge CLK_50M) begin
    spin_rate_div_q <= spin_tick ? 14'd0 : spin_rate_div_q + 14'd1;
    stick_x_last_q <= stick_x;

    if (!paddle_init_q) begin
      // Latch the resting paddle value so a missing paddle (reads 0)
      // never grabs the steering at power-up.
      paddle_init_q <= 1'b1;
      paddle_last_q <= paddle_0;
      spin_toggle_meta_q <= spinner_0[8];
      spin_toggle_sync_q <= spinner_0[8];
      spin_toggle_seen_q <= spinner_0[8];
    end else begin
      spin_toggle_meta_q <= spinner_0[8];
      spin_toggle_sync_q <= spin_toggle_meta_q;

      if (spin_event) begin
        spin_toggle_seen_q <= spin_toggle_sync_q;
        // Seed from the active axis on takeover, avoiding a steering jump.
        if (steer_src_q != 2'd2) begin
          spin_pos_q <= steer_x_raw;
          spin_pending_q <= $signed(spin_delta_units);
        end else if (spin_pending_plus_delta > 16'sd16000) begin
          spin_pending_q <= 15'sd16000;
        end else if (spin_pending_plus_delta < -16'sd16000) begin
          spin_pending_q <= -15'sd16000;
        end else begin
          spin_pending_q <= spin_pending_plus_delta[14:0];
        end
        steer_src_q <= 2'd2;
      end else begin
        if (spin_tick && (spin_pending_q >= 15'sd2)) begin
          spin_pending_q <= spin_pending_q - 15'sd2;
          if (spin_pos_q != 8'hff) spin_pos_q <= spin_pos_q + 8'd1;
        end else if (spin_tick && (spin_pending_q <= -15'sd2)) begin
          spin_pending_q <= spin_pending_q + 15'sd2;
          if (spin_pos_q != 8'h00) spin_pos_q <= spin_pos_q - 8'd1;
        end

        if (paddle_diff > 8'd2) begin
          paddle_last_q <= paddle_0;
          steer_src_q   <= 2'd1;
        end else if ((steer_src_q == 2'd2) ? stick_x_changed : stick_x_moved) begin
          steer_src_q <= 2'd0;
        end else if (joy[0] || joy[1]) begin
          steer_src_q <= 2'd3;
        end
      end
    end
  end
  wire [7:0] steer_x = status[11] ? ~steer_x_raw : steer_x_raw;
  wire [7:0] steer_y = pad_y_active ? pad_y_q : stick_y;

  wire [15:0] port_a80000 = {13'h1fff, ~btn_start, ~btn_fire_r, ~btn_fire};

  // ---- JSA II 6502 program ROM (MRA rom index 1, 64 KiB) ------------------
  logic [7:0]  snd_rom_hi_q = 8'h00;
  logic        snd_rom_wr_q = 1'b0;
  logic [14:0] snd_rom_addr_q = 15'd0;
  logic [15:0] snd_rom_data_q = 16'h0000;
  always_ff @(posedge CLK_50M) begin
    snd_rom_wr_q <= 1'b0;
    if (ioctl_wr && (ioctl_index == 16'd1)) begin
      if (!ioctl_addr[0]) begin
        snd_rom_hi_q <= ioctl_dout;
      end else begin
        snd_rom_addr_q <= ioctl_addr[15:1];
        snd_rom_data_q <= {snd_rom_hi_q, ioctl_dout};
        snd_rom_wr_q   <= 1'b1;
      end
    end
  end

  // ---- NVRAM (.nvm, ioctl index 2): 200e/210e zero RAM -------------------
  wire        nvram_req_level;
  wire        nvram_we;
  wire [11:0] nvram_addr;
  wire [7:0]  nvram_wdata;
  wire        nvram_ack_core;
  wire [7:0]  nvram_rdata_core;
  wire        nvram_dirty_core;
  // DIP switches (ioctl index 254): byte 0 = SW1, byte 1 bit 0 = DIAGN.
  logic [7:0] dip_sw1_q = 8'h00;
  logic [7:0] dip_misc_q = 8'h01;
  always_ff @(posedge CLK_50M) begin
    if (ioctl_wr && (ioctl_index == 16'd254) && (ioctl_addr[24:1] == 24'd0)) begin
      if (ioctl_addr[0]) dip_misc_q <= ioctl_dout;
      else               dip_sw1_q  <= ioctl_dout;
    end
  end

  wire reset = RESET | status[0] | buttons[1] | ioctl_download;
  wire ce_pix;
  wire hblank, vblank, hsync, vsync;
  wire [23:0] rgb;
  wire pix_clk, pix_ce, pix_hblank, pix_vblank, pix_hsync, pix_vsync;
  wire [23:0] pix_rgb;
  wire [31:0] debug;
  wire clk_core;

  harddrivin_nvram_bridge u_nvram_bridge (
    .hps_clk_i(CLK_50M),
    .ioctl_download_i(ioctl_download), .ioctl_upload_i(ioctl_upload),
    .ioctl_wr_i(ioctl_wr), .ioctl_rd_i(ioctl_rd), .ioctl_index_i(ioctl_index),
    .ioctl_addr_i(ioctl_addr[11:0]), .ioctl_dout_i(ioctl_dout),
    .ioctl_wait_o(nvram_ioctl_wait), .ioctl_din_o(nvram_ioctl_din),
    .ioctl_upload_req_o(nvram_save_req),
    .core_clk_i(clk_core), .core_req_o(nvram_req_level),
    .core_we_o(nvram_we), .core_addr_o(nvram_addr),
    .core_wdata_o(nvram_wdata), .core_ack_i(nvram_ack_core),
    .core_rdata_i(nvram_rdata_core), .core_dirty_i(nvram_dirty_core)
  );

  // Input clock-domain note: the ADC and switch values are quasi-static
  // levels sampled by the 68010 bus, exactly as in the Hard Drivin' top.
  harddrivin_milestone #(
    .COCKPIT(1'b0),
    .STUNRUN(1'b1),
    .DIAG_FULL(1'b0),
    .ZERO_RAM_INIT_HI_FILE("generated/zram_stunrun_200e.hex"),
    .ZERO_RAM_INIT_LO_FILE("generated/zram_stunrun_210e.hex")
  ) u_milestone (
    .clk_50_i(CLK_50M), .rst_i(reset), .clk_core_o(clk_core), .ce_pix_o(ce_pix),
    .hblank_o(hblank), .vblank_o(vblank), .hsync_o(hsync),
    .vsync_o(vsync), .rgb_o(rgb), .debug_o(debug),
    .pix_clk_o(pix_clk), .pix_ce_o(pix_ce), .pix_hblank_o(pix_hblank),
    .pix_vblank_o(pix_vblank), .pix_hsync_o(pix_hsync), .pix_vsync_o(pix_vsync),
    .pix_rgb_o(pix_rgb),
    .diagnostic_enable_i(1'b0),
    .controls_overlay_i(1'b0),
    .analog_axes_i({16'h8080, steer_y, steer_x}),
    .axis_moved_i(4'd0),
    .pot_prompt_active_o(), .brake_calibration_active_o(),
    .shifter_calibration_active_o(), .seat_calibration_active_o(),
    .calibration_active_o(),
    .coin1_i(btn_coin), .coin2_i(1'b0),
    .service_i(service_mode), .diag_jumper_i(dip_misc_q[0]), .sw1_i(dip_sw1_q),
    .compact_port1_i(port_a80000),
    // 8-bit ADC: channel 0 = X (accelerator_i), channel 2 = Y (seat_i).
    .accelerator_i(steer_x), .seat_i(steer_y),
    .clutch_i(8'hff), .shifter_x_i(8'hff), .shifter_y_i(8'hff), .brake_i(8'hff),
    .steering_i(12'h800), .brake12_i(12'hfff), .audio_o(sound_audio),
    .snd_rom_wr_clk_i(CLK_50M), .snd_rom_wr_en_i(snd_rom_wr_q),
    .snd_rom_wr_addr_i(snd_rom_addr_q), .snd_rom_wr_data_i(snd_rom_data_q),
    .nvram_req_i(nvram_req_level), .nvram_we_i(nvram_we), .nvram_addr_i(nvram_addr),
    .nvram_wdata_i(nvram_wdata), .nvram_ack_o(nvram_ack_core),
    .nvram_rdata_o(nvram_rdata_core), .nvram_dirty_o(nvram_dirty_core),
    .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE)
  );
  assign DDRAM_CLK = clk_core;

  wire vga_de;
  arcade_video #(.WIDTH(512), .DW(24), .GAMMA(1)) u_video (
    .clk_video(pix_clk), .ce_pix(pix_ce), .RGB_in(pix_rgb),
    .HBlank(pix_hblank), .VBlank(pix_vblank), .HSync(pix_hsync), .VSync(pix_vsync),
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de), .VGA_SL(VGA_SL),
    .fx(status[8:6]), .forced_scandoubler(forced_scandoubler), .gamma_bus(gamma_bus)
  );

  wire [1:0] ar = status[122:121];
  video_freak u_video_freak (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de),
    .ARX((ar == 2'd0) ? 12'd4 : 12'(ar - 2'd1)), .ARY((ar == 2'd0) ? 12'd3 : 12'd0),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE({1'b0, status[5:4]})
  );

  assign LED_USER = debug[22] ^ debug[9];

  logic unused_inputs;
  always_comb unused_inputs = CLK_AUDIO ^ SD_MISO ^ SD_CD ^ UART_CTS ^
                              UART_RXD ^ UART_DSR ^ ^USER_IN ^ OSD_STATUS ^
                              ^ioctl_addr[24:16];
endmodule
