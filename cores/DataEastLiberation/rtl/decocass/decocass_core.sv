//============================================================================
// Data East DECO Cassette engine adapter for the universal Liberation core.
// Functional blocks are carried from examples/Arcade-DECOCassette_MiSTer.
// This adapter targets the requested Type-3 cprobowl/cpsoccer sets only.
//============================================================================

module decocass_core (
  input             clk_sys,          // 48 MHz universal system clock
  input             reset_in,
  input             original_tape_speed,
  input             pause,
  // Hi-score port: while hs_active the CPUs are paused; the port reads/writes main work RAM
  input             hs_active,
  input      [15:0] hs_addr,
  input             hs_wr,
  input       [7:0] hs_wdata,
  output      [7:0] hs_rdata,
  input       [7:0] p1,               // active-low MAME-style inputs
  input       [7:0] p2,
  input       [7:0] p3,
  input       [7:0] dsw1,
  input       [7:0] dsw2,
  input             ioctl_download,
  input       [7:0] ioctl_index,
  input      [24:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_wr,
  output     [15:0] ext_tape_rd_addr,
  input       [7:0] ext_tape_rd_data,
  output     [15:0] ext_tape_wr_addr,
  output      [7:0] ext_tape_wr_data,
  output            ext_tape_wr_en,
  output      [3:0] red,
  output      [3:0] green,
  output      [3:0] blue,
  output            hs,
  output            vs,
  output            hb,
  output            vb,
  output            ce_pix,
  output     [15:0] audio_l,
  output     [15:0] audio_r,
  output            flip_screen,
  output            tape_active
);

// Hi-score bus inputs are registered locally: keeps the bus-mux select short and close to its loads.
reg        hs_active_q;
reg [15:0] hs_addr_q;
reg        hs_wr_q;
reg  [7:0] hs_wdata_q;
always @(posedge clk_sys) begin
  hs_active_q <= hs_active;
  hs_addr_q   <= hs_addr;
  hs_wr_q     <= hs_wr;
  hs_wdata_q  <= hs_wdata;
end

wire reset;
wire watchdog_reset;
wire pause_cpu = pause;
wire [15:0] cpu_addr;
wire [7:0] cpu_dout;
wire cpu_rw_n, cpu_sync;
wire tape_direction;

// The source engine used 96 MHz. These half-size divisors retain the exact
// board rates at 48 MHz: pixel/HCLK=6 MHz, HCLK1=3 MHz, HCLK2=1.5 MHz,
// HCLK4=750 kHz, audio=500 kHz, and tape=4.8 kHz.
reg [5:0] hclk_count = 6'd0;
reg hclk_reset_d = 1'b0;
always @(posedge clk_sys) hclk_reset_d <= reset;
always @(posedge clk_sys) begin
  // Raster/HCLK continues during the loader's held game reset. CPU and
  // rendering state retain their separate reset qualification below.
  if (reset && !hclk_reset_d) hclk_count <= 6'd0;
  else hclk_count <= hclk_count + 6'd1;
end
wire ce_hclk_raw  = (hclk_count[2:0] == 3'b111);
wire ce_hclk1_raw = (hclk_count[3:0] == 4'b1111);
wire ce_hclk2_raw = (hclk_count[4:0] == 5'b11111);
wire ce_hclk4_raw = (hclk_count[5:0] == 6'b111111);
// Accelerate the actual BIOS/8041 transfer, retaining every tape clock and
// CRC/dongle transaction. After the first payload byte, keep BIOS checksum
// work fast across motor stops. The first non-BIOS instruction fetch ends
// that extension permanently; pre-load RAM self-tests cannot arm it.
// Change rates only on a common divider boundary.
reg load_turbo = 1'b0;
reg boot_payload_seen = 1'b0;
reg boot_ram_entered = 1'b0;
always @(posedge clk_sys) begin
  if (reset) load_turbo <= 1'b0;
  else if (ce_hclk4_raw && !pause_cpu)
    load_turbo <= !original_tape_speed &&
                  (tape_motor_on || (boot_payload_seen && !boot_ram_entered));
end
wire ce_hclk  = (load_turbo || ce_hclk_raw) & ~pause_cpu;
wire ce_hclk1 = (load_turbo ? hclk_count[0] : ce_hclk1_raw) & ~pause_cpu;
wire ce_hclk2 = ce_hclk2_raw & ~pause_cpu;
wire ce_hclk4 = (load_turbo ? ce_hclk_raw : ce_hclk4_raw) & ~pause_cpu;
assign ce_pix = ce_hclk_raw;

always @(posedge clk_sys) begin
  if (reset) begin
    boot_payload_seen <= 1'b0;
    boot_ram_entered <= 1'b0;
  end else if (!pause_cpu) begin
    if (tape_motor_on && tape_direction && (|ext_tape_rd_addr))
      boot_payload_seen <= 1'b1;
    if (ce_hclk4 && boot_payload_seen && cpu_sync && (cpu_addr[15:12] != 4'hf))
      boot_ram_entered <= 1'b1;
  end
end

reg [3:0] audio_div = 4'd0;
always @(posedge clk_sys) begin
  if (reset) audio_div <= 4'd0;
  else if (ce_hclk_raw) audio_div <= (audio_div == 4'd11) ? 4'd0 : audio_div + 4'd1;
end
wire ce_audio_raw = ce_hclk_raw && (audio_div == 4'd11);
wire ce_audio = ce_audio_raw & ~pause_cpu;

wire clk_8041 = clk_sys; // retained compatibility port; current i8041_top uses clk_sys/ce_hclk

// Graphics subsystem address/data buses (ports B from dual-port RAMs).
wire [9:0]  fgvram_addr_gfx, colram_addr_gfx;
wire [10:0] tilram_addr_gfx;
wire [9:0]  objram_addr_gfx;
wire [7:0]  fgvram_q_gfx, colram_q_gfx;
wire [7:0]  tilram_q_gfx, objram_q_gfx;
wire [7:0]  e5xx_dongle;
wire [7:0]  e5xx_to_cpu;
wire [7:0]  bios_dout_cpu;
wire        bios_we_cpu_int;
wire        video_vblank, video_hsync, video_vsync, video_hblank;
wire [8:0]  hcnt, vcnt;

// Preserve the source wrapper's byte order while accepting universal DIPs.
wire [7:0] sw [0:7];
assign sw[0] = 8'h00;
assign sw[1] = 8'h00;
assign sw[2] = dsw2;
assign sw[3] = dsw1;
assign sw[4] = 8'h00;
assign sw[5] = 8'h00;
assign sw[6] = 8'h00;
assign sw[7] = 8'h00;

wire [15:0] joystick_0 = {
  6'd0, 1'b0, ~p3[3], ~p3[2], ~p3[0],
  ~p1[5], ~p1[4], ~p1[2], ~p1[3], ~p1[1], ~p1[0]
};
wire [15:0] joystick_1 = {
  6'd0, 1'b0, 1'b0, 1'b0, ~p3[1],
  ~p2[5], ~p2[4], ~p2[2], ~p2[3], ~p2[1], ~p2[0]
};

// Extract metadata from ROM loader
wire [7:0] dongle_type_byte;
wire [7:0] game_id_byte;
wire [7:0] swap_mode_byte;
wire [3:0] swap_mode = swap_mode_byte[3:0];  // From metadata $02E02 (was sw[1])
wire type3_metadata_valid = (dongle_type_byte[3:0] == 4'd3);
assign reset = reset_in | ioctl_download | ~type3_metadata_valid | watchdog_reset;

// =========================================================================
// ROM LOADER (task 25)
// =========================================================================
wire        bios_we_rom, abios_we_rom, mcurom_we;
wire [11:0] bios_addr_rom;
wire [10:0] abios_addr_rom;
wire [9:0]  mcurom_addr;
wire [7:0]  bios_dout_rom, abios_dout_rom, mcurom_dout;
wire        palprom_we;
wire [7:0]  palprom_addr, palprom_dout;
wire        dongleprom_we;
wire [17:0] dongleprom_addr;   // widened for the 256 KB multigame dongle (loaded via ioctl index 1)
wire [7:0]  dongleprom_dout;

rom_loader rom_loader_inst (
	.clk_sys               (clk_sys),
	.ioctl_download        (ioctl_download),
	.ioctl_wr              (ioctl_wr),
	.ioctl_addr            (ioctl_addr),
	.ioctl_dout            (ioctl_dout),
	.ioctl_index           (ioctl_index),
	.bios_we               (bios_we_rom),
	.bios_addr             (bios_addr_rom),
	.bios_dout             (bios_dout_rom),
	.abios_we              (abios_we_rom),
	.abios_addr            (abios_addr_rom),
	.abios_dout            (abios_dout_rom),
	.mcurom_we             (mcurom_we),
	.mcurom_addr           (mcurom_addr),
	.mcurom_dout           (mcurom_dout),
	.palprom_we            (palprom_we),
	.palprom_addr          (palprom_addr),
	.palprom_dout          (palprom_dout),
	.dongleprom_we         (dongleprom_we),
	.dongleprom_addr       (dongleprom_addr),
	.dongleprom_dout       (dongleprom_dout),
	.metadata_dongle_type  (dongle_type_byte),
	.metadata_game_id      (game_id_byte),
	.metadata_swap_mode    (swap_mode_byte)
);

// =========================================================================
// MEMORY: BIOS ROM (main CPU $F000-$FFFF, 4 KB)
// =========================================================================
wire [11:0] bios_addr_cpu;
wire [11:0] bios_addr_cpu_dec;     // address from decocass (CPU-side)
wire        bios_we_cpu;
wire [7:0]  bios_dw_cpu, bios_q;

spram #(.address_width(12), .data_width(8)) bios_rom (
	.clock     (clk_sys),
	.enable    (1'b1),
	.address   (bios_addr_cpu),
	.data      (bios_dw_cpu),
	.wren      (bios_we_cpu),
	.q         (bios_q)
);

// ROM loader and CPU write arbitration for BIOS
assign bios_addr_cpu = bios_we_rom ? bios_addr_rom : bios_addr_cpu_dec;
assign bios_we_cpu   = bios_we_rom | (bios_we_cpu_int & ce_hclk4);
assign bios_dw_cpu   = bios_we_rom ? bios_dout_rom : bios_dout_cpu;

// =========================================================================
// MEMORY: Work RAM (main CPU $0000-$5FFF, 24 KB = 15-bit address)
// =========================================================================
wire [14:0] ram_addr_cpu;
wire        ram_we_cpu;
wire [7:0]  ram_dw_cpu, ram_q;

spram #(.address_width(15), .data_width(8)) work_ram (
	.clock     (clk_sys),
	.enable    (1'b1),
	.address   (hs_active_q ? hs_addr_q[14:0] : ram_addr_cpu),
	.data      (hs_active_q ? hs_wdata_q : ram_dw_cpu),
	.wren      (hs_active_q ? (hs_wr_q && hs_addr_q < 16'h6000) : ram_we_cpu),
	.q         (ram_q)
);
reg [7:0] hs_rdata_r;
always @(posedge clk_sys) hs_rdata_r <= ram_q;   // registered for timing symmetry with the other engines
assign hs_rdata = hs_rdata_r;

// =========================================================================
// MEMORY: Charram CPU-readback path ($6000-$BFFF, 24 KB total — 3 planes × 8 KB)
// =========================================================================
// Keep a linear CPU readback copy; the renderer and sprite engines require
// independent simultaneous plane reads.
wire [14:0] charram_addr_cpu;
wire        charram_we_p0, charram_we_p1, charram_we_p2;
wire        charram_we_any = charram_we_p0 | charram_we_p1 | charram_we_p2;
wire [7:0]  charram_dw_cpu, charram_q;

spram #(.address_width(15), .data_width(8)) charram (
	.clock     (clk_sys),
	.enable    (1'b1),
	.address   (charram_addr_cpu),
	.data      (charram_dw_cpu),
	.wren      (charram_we_any),
	.q         (charram_q)
);

// =========================================================================
// MEMORY: FG Video RAM ($C000-$C3FF + mirror $C800-$CBFF, 1 KB = 10-bit)
// =========================================================================
wire [9:0]  fgvram_addr_cpu;
wire        fgvram_we_cpu;
wire [7:0]  fgvram_dw_cpu, fgvram_q;

dpram #(.address_width(10), .data_width(8)) fgvram (
	.clock_a   (clk_sys),
	.enable_a  (1'b1),
	.address_a (fgvram_addr_cpu),
	.data_a    (fgvram_dw_cpu),
	.wren_a    (fgvram_we_cpu),
	.q_a       (fgvram_q),
	.clock_b   (clk_sys),
	.enable_b  (1'b1),
	.address_b (fgvram_addr_gfx),
	.data_b    (8'h00),
	.wren_b    (1'b0),
	.q_b       (fgvram_q_gfx)
);

// =========================================================================
// MEMORY: Color RAM ($C400-$C7FF + mirror $CC00-$CFFF, 1 KB = 10-bit)
// =========================================================================
wire [9:0]  colram_addr_cpu;
wire        colram_we_cpu;
wire [7:0]  colram_dw_cpu, colram_q;

dpram #(.address_width(10), .data_width(8)) colram (
	.clock_a   (clk_sys),
	.enable_a  (1'b1),
	.address_a (colram_addr_cpu),
	.data_a    (colram_dw_cpu),
	.wren_a    (colram_we_cpu),
	.q_a       (colram_q),
	.clock_b   (clk_sys),
	.enable_b  (1'b1),
	.address_b (colram_addr_gfx),
	.data_b    (8'h00),
	.wren_b    (1'b0),
	.q_b       (colram_q_gfx)
);

// =========================================================================
// MEMORY: Tileram ($D000-$D7FF, 2 KB = 11-bit)
// =========================================================================
wire [10:0] tilram_addr_cpu;
wire        tilram_we_cpu;
wire [7:0]  tilram_dw_cpu, tilram_q;

dpram #(.address_width(11), .data_width(8)) tilram (
	.clock_a   (clk_sys),
	.enable_a  (1'b1),
	.address_a (tilram_addr_cpu),
	.data_a    (tilram_dw_cpu),
	.wren_a    (tilram_we_cpu),
	.q_a       (tilram_q),
	.clock_b   (clk_sys),
	.enable_b  (1'b1),
	.address_b (tilram_addr_gfx),
	.data_b    (8'h00),
	.wren_b    (1'b0),
	.q_b       (tilram_q_gfx)
);

// =========================================================================
// MEMORY: Objectram ($D800-$DBFF, 1 KB = 10-bit)
// =========================================================================
wire [9:0]  objram_addr_cpu;
wire        objram_we_cpu;
wire [7:0]  objram_dw_cpu, objram_q;

dpram #(.address_width(10), .data_width(8)) objram (
	.clock_a   (clk_sys),
	.enable_a  (1'b1),
	.address_a (objram_addr_cpu),
	.data_a    (objram_dw_cpu),
	.wren_a    (objram_we_cpu),
	.q_a       (objram_q),
	.clock_b   (clk_sys),
	.enable_b  (1'b1),
	.address_b (objram_addr_gfx),
	.data_b    (8'h00),
	.wren_b    (1'b0),
	.q_b       (objram_q_gfx)
);

// =========================================================================
// MEMORY: Palette RAM ($E000-$E0FF, 256 bytes = 8-bit)
// =========================================================================
wire [7:0]  palram_addr_cpu;
wire        palram_we_cpu;
wire [7:0]  palram_dw_cpu, palram_q;

dpram #(.address_width(8), .data_width(8)) palram (
	.clock_a   (clk_sys),
	.enable_a  (1'b1),
	.address_a (palram_addr_cpu),
	.data_a    (palram_dw_cpu),
	.wren_a    (palram_we_cpu),
	.q_a       (palram_q),
	.clock_b   (clk_sys),
	.enable_b  (1'b1),
	.address_b (8'h00),
	.data_b    (8'h00),
	.wren_b    (1'b0),
	.q_b       ()
);

// =========================================================================
// MAIN CPU: DECO-222 @ 750 kHz (ce_hclk4 = HCLK4, per MAME decocass.cpp:1018)
// =========================================================================

// Write strobes from decocass
wire cpu_we_ram, cpu_we_charram, cpu_we_fgvram, cpu_we_colram;
wire cpu_we_tilram, cpu_we_objram, cpu_we_palram;
wire cpu_we_e3xx, cpu_we_e4xx, cpu_we_e414, cpu_we_e5xx, cpu_re_e5xx;
wire cpu_we_e6xx, cpu_we_e7xx, cpu_re_e700, cpu_re_e701;

// $E400 decocass_reset_w: bit 0 asserts the audio-CPU reset and bit 3
// asserts the 8041 reset. This is separate from the whole-engine reset.
reg [7:0] subsystem_reset = 8'h00;
always @(posedge clk_sys) begin
  if (reset)
    subsystem_reset <= 8'h00;
  else if (cpu_we_e4xx && (cpu_addr == 16'he400))
    subsystem_reset <= cpu_dout;
end

// Control register outputs
wire [7:0] mode_set_reg, back_h_shift_reg, back_vl_shift_reg, back_vr_shift_reg;
wire [7:0] part_h_shift_reg, part_v_shift_reg, color_center_bot_reg;
wire [7:0] color_missiles_reg;   // MISSILES-IMPL-2026-06-28: $E302 missile color latch
wire [7:0] center_h_shift_space_reg, center_v_shift_reg, coin_counter_reg, nmi_reset_reg;

// Main CPU memmap decoder
decocass decocass_inst (
	.clk_sys           (clk_sys),
	.ce_main           (ce_hclk4),        // 750 kHz CPU clock (HCLK4 per MAME decocass.cpp:1018)
	.reset             (reset),
	.cpu_addr          (cpu_addr),
	.cpu_dout          (cpu_dout),
	.cpu_rw_n          (cpu_rw_n),
	.cpu_sync          (cpu_sync),
	.cpu_we_ram        (cpu_we_ram),
	.cpu_we_charram    (cpu_we_charram),
	.cpu_we_fgvram     (cpu_we_fgvram),
	.cpu_we_colram     (cpu_we_colram),
	.cpu_we_tilram     (cpu_we_tilram),
	.cpu_we_objram     (cpu_we_objram),
	.cpu_we_palram     (cpu_we_palram),
	.cpu_we_e3xx       (cpu_we_e3xx),
	.cpu_we_e4xx       (cpu_we_e4xx),
	.cpu_we_e414       (cpu_we_e414),
	.cpu_we_e5xx       (cpu_we_e5xx),
	.cpu_re_e5xx       (cpu_re_e5xx),
	.cpu_we_e6xx       (cpu_we_e6xx),
	.cpu_we_e7xx       (cpu_we_e7xx),
	.cpu_re_e700       (cpu_re_e700),
	.cpu_re_e701       (cpu_re_e701),
	.sound_data        (sound_data),
	.sound_ack         (sound_ack),
	.e5xx_dongle_q     (e5xx_to_cpu),
	.input_q           (input_q),
	.bios_q            (bios_q),
	.ram_q             (ram_q),
	.charram_q         (charram_q),
	.fgvram_q          (fgvram_q),
	.colram_q          (colram_q),
	.tilram_q          (tilram_q),
	.objram_q          (objram_q),
	.palram_q          (palram_q),
	// The universal MRAs now load the correct MD-Small default themselves.
	// Preserve both physical tape-type bits so an OSD change reaches the BIOS
	// instead of being silently forced back to $30 by adapter glue.
	.dsw1              (sw[3]),
	.dsw2              (sw[2]),
	.vblank            (video_vblank),
	// CONTROLS-FIX-2026-06-08: coin moved to joy[6] to match new CONF_STR (Coin=bit6).
	// NOTE: coin_in feeds the MAIN-CPU NMI — the ONLY joystick line with a path to the loader.
	// If the loader regresses on this build, flip back to the commented line below (joy[14]) to
	// isolate — no rebuild-from-memory needed:
	// .coin_in           (joystick_0[14] | joystick_1[14]),  // P1 or P2 coin → main-CPU NMI (MAME decocass_m.cpp:155-159)
	.coin_in           (joystick_0[6] | joystick_1[6]),  // P1/P2 coin → main-CPU NMI
	.ram_addr_w        (ram_addr_cpu),
	.ram_we_w          (ram_we_cpu),
	.ram_dw            (ram_dw_cpu),
	.charram_addr_w    (charram_addr_cpu),
	.charram_we_p0     (charram_we_p0),
	.charram_we_p1     (charram_we_p1),
	.charram_we_p2     (charram_we_p2),
	.charram_dw        (charram_dw_cpu),
	.fgvram_addr_w     (fgvram_addr_cpu),
	.fgvram_we_w       (fgvram_we_cpu),
	.fgvram_dw         (fgvram_dw_cpu),
	.colram_addr_w     (colram_addr_cpu),
	.colram_we_w       (colram_we_cpu),
	.colram_dw         (colram_dw_cpu),
	.tilram_addr_w     (tilram_addr_cpu),
	.tilram_we_w       (tilram_we_cpu),
	.tilram_dw         (tilram_dw_cpu),
	.objram_addr_w     (objram_addr_cpu),
	.objram_we_w       (objram_we_cpu),
	.objram_dw         (objram_dw_cpu),
	.palram_addr_w     (palram_addr_cpu),
	.palram_we_w       (palram_we_cpu),
	.palram_dw         (palram_dw_cpu),
	.bios_addr_w       (bios_addr_cpu_dec),
	.bios_we_w         (bios_we_cpu_int),
	.bios_dw           (bios_dout_cpu),
	.mode_set_reg      (mode_set_reg),
	.back_h_shift_reg  (back_h_shift_reg),
	.back_vl_shift_reg (back_vl_shift_reg),
	.back_vr_shift_reg (back_vr_shift_reg),
	.part_h_shift_reg  (part_h_shift_reg),
	.part_v_shift_reg  (part_v_shift_reg),
	.color_center_bot_reg (color_center_bot_reg),
	.color_missiles_reg (color_missiles_reg),
	.center_h_shift_space_reg (center_h_shift_space_reg),
	.center_v_shift_reg    (center_v_shift_reg),
	.coin_counter_reg      (coin_counter_reg),
	.nmi_reset_reg         (nmi_reset_reg)
);

// =========================================================================
// MCU: i8041 + Program Memory + Tape Interface (tasks 15-17)
// =========================================================================
wire [7:0]  mcu_p1_out, mcu_p2_out, mcu_p1_in, mcu_p2_in;
wire        mcu_t0, mcu_t1;
wire [7:0]  mcu_host_dout;
wire [7:0]  mcu_host_sts;       // DBBSTS exposure 2026-05-30: real STATUS reg from the i8041 core
wire        mcu_host_dout_oe;
wire        iface_tape_motor_on, iface_tape_direction;
wire [1:0]  iface_tape_speed_select;
wire        tape_data, tape_clock, tape_bot, tape_eot;

// Literal MAME/PCB P1 transport truth table. Only 01 (forward) and 10
// (reverse) drive the deck; 00 and 11 are stopped. The previous inherited
// approximation decoded each active-low bit independently, so P1[5:4]=00
// incorrectly drove both directions and ultimately advanced the tape.
wire tape_forward = (mcu_p1_out[5:4] == 2'b01);
wire tape_reverse = (mcu_p1_out[5:4] == 2'b10);
wire tape_motor_on = tape_forward | tape_reverse;
assign tape_direction = tape_forward;
wire tape_fast = ~mcu_p1_out[2];
wire [1:0] tape_speed_select = !tape_motor_on ? 2'b00 :
                               tape_fast     ? 2'b10 : 2'b01;

// MAME changes the timer rate to 4.8 kHz or 33.6 kHz; it does not jump the
// tape position seven clocks at a 4.8 kHz rate. A 10,000-state fractional
// accumulator preserves that observable clock cadence exactly at 48 MHz:
// add 1 for normal transport, 7 for fast transport, and move one tape clock
// on each carry. This retains intermediate RCLK/RDATA/BOT/EOT states.
reg [13:0] tape_phase = 14'd0;
wire [5:0] tape_phase_step = load_turbo ? (tape_fast ? 6'd56 : 6'd8)
                                                   : (tape_fast ? 6'd7 : 6'd1);
wire [14:0] tape_phase_sum = {1'b0, tape_phase} + {9'd0, tape_phase_step};
wire ce_tape_raw = tape_motor_on && (tape_phase_sum >= 15'd10000);
wire [14:0] tape_phase_next = ce_tape_raw ? tape_phase_sum - 15'd10000 : tape_phase_sum;
wire ce_tape = ce_tape_raw & ~pause_cpu;
always @(posedge clk_sys) begin
  if (reset || !tape_motor_on)
    tape_phase <= 14'd0;
  else if (!pause_cpu)
    tape_phase <= tape_phase_next[13:0];
end

// i8041 MCU + program memory
i8041_top i8041_inst (
	.clk_sys         (clk_sys),
	.ce_hclk         (ce_hclk),
	.clk_8041        (clk_8041),
	.reset_n         (~(reset | subsystem_reset[3])),
	.cs_n            (mcu_cs_n),
	.rd_n            (mcu_rd_n),
	.wr_n            (mcu_wr_n),
	.a0              (mcu_a0),
	.host_din        (mcu_host_din),
	.host_dout       (mcu_host_dout),
	.host_sts        (mcu_host_sts),       // DBBSTS exposure 2026-05-30
	.host_dout_oe    (mcu_host_dout_oe),
	.sync_o          (),
	.t0_i            (mcu_t0),
	.t1_i            (mcu_t1),
	.p1_i            (mcu_p1_in),
	.p1_o            (mcu_p1_out),
	.p1_low_imp      (),
	.p2_i            (mcu_p2_in),
	.p2_o            (mcu_p2_out),
	.p2l_low_imp     (),
	.p2h_low_imp     (),
	.prog_n          (),
	.rom_we          (mcurom_we),
	.rom_addr_w      (mcurom_addr),
	.rom_data_w      (mcurom_dout),
	.pmem_addr_o     (),
	.dmem_r3_o       (),
	.dmem_r5_o       (),
	.dmem_r1_o       ()
);

// MCU ↔ Tape ↔ Main CPU interface
wire [7:0]  dongle_addr_lo;
wire        dongle_re, dongle_we;
wire        iface_dongle_re, iface_dongle_we;
wire [7:0]  dongle_dout;
wire [3:0]  dongle_din_low4;    // legacy 4-bit nibble (mcu_tape_iface still uses it)
wire [7:0]  dongle_din_full;    // 2026-05-18 — full 8-bit dongle output (per MAME)
wire        mcu_cs_n, mcu_rd_n, mcu_wr_n, mcu_a0;
wire [7:0]  mcu_host_din;  // CPU dout, latched by iface, presented to i8041

// In Type-3 PROM mode MAME routes $E5x0/$E5x1 only to the PAL/PROM. Reads and
// counter-load writes must not also strobe the 8041 host bus. Mirror PAL pin 19
// here so the shared host-interface block can be gated independently while the
// Type-3 dongle continues to receive every access.
reg type3_prom_mode;
always @(posedge clk_sys) begin
	if (reset)
		type3_prom_mode <= 1'b0;
	else if (dongle_we && dongle_addr_lo[0] && (dongle_dout[7:4] == 4'hc))
		type3_prom_mode <= 1'b1;
end

assign dongle_re = cpu_re_e5xx & ~cpu_addr[1];
assign dongle_we = cpu_we_e5xx & ~cpu_addr[1];

mcu_tape_iface mcu_tape_iface_inst (
	.clk_sys              (clk_sys),
	.ce_hclk              (ce_hclk),
	.ce_hclk1             (ce_hclk1),
	.ce_tape              (ce_tape),
	.reset                (reset),
	.mcu_p1_in            (mcu_p1_in),
	.mcu_p1_out           (mcu_p1_out),
	.mcu_p2_in            (mcu_p2_in),
	.mcu_p2_out           (mcu_p2_out),
	.mcu_t0               (mcu_t0),
	.mcu_t1               (mcu_t1),
	.mcu_cs_n             (mcu_cs_n),
	.mcu_rd_n             (mcu_rd_n),
	.mcu_wr_n             (mcu_wr_n),
	.mcu_a0               (mcu_a0),
	.mcu_dout             (mcu_host_din),
	.tape_motor_on        (iface_tape_motor_on),
	.tape_direction       (iface_tape_direction),
	.tape_speed_select    (iface_tape_speed_select),
	.tape_data            (tape_data),
	.tape_clock           (tape_clock),
	.tape_bot             (tape_bot),
	.tape_eot             (tape_eot),
	.cpu_e5_re            (cpu_re_e5xx & ~type3_prom_mode),
	.cpu_e5_we            (cpu_we_e5xx & ~type3_prom_mode),
	.cpu_addr_lo          (cpu_addr[7:0]),
	.cpu_dout             (cpu_dout),
	.cpu_din              (e5xx_dongle),
	.mcu_host_dout        (mcu_host_dout),
	.mcu_host_dout_oe     (mcu_host_dout_oe),
	.dongle_addr_lo       (dongle_addr_lo),
	.dongle_re            (iface_dongle_re),
	.dongle_we            (iface_dongle_we),
	.dongle_dout          (dongle_dout),
	.dongle_din_low4      (dongle_din_low4)
);

// E5xx dongle response is automatically composed in mcu_tape_iface
// as {mcu_p2_out[7:4], dongle_din_low4}

// =========================================================================
// CASSETTE BRAM (64 KB) + cassette_loader (task 25 / phase 16)
// =========================================================================
// 64 KB covers all known DECO cassettes (largest is 0x10000 = 64 KB; most
// are 0x8000 = 32 KB). cassette_loader writes from hps_io on port A;
// tape_streamer reads on port B during playback.
wire [15:0] cass_load_addr;
wire [7:0]  cass_load_dout;
wire        cass_load_we;
wire [17:0] tape_image_size;
assign ext_tape_wr_addr = cass_load_addr;
assign ext_tape_wr_data = cass_load_dout;
assign ext_tape_wr_en   = cass_load_we;

// A DECO board reset stops the cassette motor but does not mechanically
// rewind the deck. MAME's decocass_tape_device::device_reset likewise calls
// change_speed(0) without changing m_clockpos. Reset the virtual mechanism
// only while a cassette/dongle image is being inserted; ordinary user and
// watchdog resets preserve its position just like the PCB.
wire tape_media_reset = ioctl_download;

// 2026-05-18 — CRC16 table wires (computed by cassette_loader, read by tape_streamer)
wire [7:0]  crc_table_addr_w;
wire [15:0] crc_table_data_w;
wire        crc_table_we_w;

cassette_loader cassette_loader_inst (
    .clk_sys          (clk_sys),
    .ioctl_download   (ioctl_download),
    .ioctl_wr         (ioctl_wr),
    .ioctl_addr       (ioctl_addr),
    .ioctl_dout       (ioctl_dout),
    .bram_addr        (cass_load_addr),
    .bram_dout        (cass_load_dout),
    .bram_we          (cass_load_we),
    .crc_table_addr   (crc_table_addr_w),
    .crc_table_data   (crc_table_data_w),
    .crc_table_we     (crc_table_we_w),
    .image_size_bytes (tape_image_size)
);

// CRC16 lookup table — 256 blocks × 16 bits.
// Port A: written by cassette_loader as bytes stream in.
// Port B: read by tape_streamer when streaming CRC bytes.
wire [7:0]  crc_table_q_addr;
wire [15:0] crc_table_q;
dpram #(.address_width(8), .data_width(16)) crc16_table_bram (
    .clock_a  (clk_sys),
    .enable_a (1'b1),
    .wren_a   (crc_table_we_w),
    .address_a(crc_table_addr_w),
    .data_a   (crc_table_data_w),
    .q_a      (),
    .clock_b  (clk_sys),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(crc_table_q_addr),
    .data_b   (16'h0000),
    .q_b      (crc_table_q)
);

// Tape Streamer (task 16)
wire [17:0] tape_image_addr;
wire [7:0]  tape_image_q = ext_tape_rd_data;
assign ext_tape_rd_addr = tape_image_addr[15:0];

tape_streamer tape_streamer_inst (
	.clk_sys           (clk_sys),
	.ce_tape           (ce_tape),
	.reset             (tape_media_reset),
	.image_addr        (tape_image_addr),
	.image_q           (tape_image_q),
	.image_size_bytes  (tape_image_size),
	.motor_on          (tape_motor_on),
	.direction         (tape_direction),
	// ce_tape is already speed-scaled (4.8/33.6 kHz), so advance one
	// physical tape clock per enable instead of skipping seven states.
	.speed_select      (2'b01),
	.crc_addr          (crc_table_q_addr),
	.crc_q             (crc_table_q),
	.tape_data         (tape_data),
	.tape_clock        (tape_clock),
	.tape_bot          (tape_bot),
	.tape_eot          (tape_eot)
);

// =========================================================================
// TYPE-3 DONGLE
// =========================================================================
wire [11:0] dprom_addr;
wire [7:0]  dprom_q;

// Both requested cassette games use the same Type-3 PAL/PROM interface. A
// direct instance avoids synthesizing unrelated dongle and multigame paths.
dongle_type3 dongle_type3_inst (
	.clk_sys           (clk_sys),
	.ce_hclk4          (ce_hclk4),
	.reset             (reset),
	.swap_mode         (swap_mode),
	.cpu_re            (dongle_re),
	.cpu_we            (dongle_we),
	.cpu_addr_lo       (dongle_addr_lo),
	.cpu_dout          (dongle_dout),
	.cpu_din_full      (dongle_din_full),       // 2026-05-18: 8-bit per MAME
	.prom_addr         (dprom_addr),
	.prom_q            (dprom_q),
	// 2026-05-18 — dongle reads MCU host-bus registers per MAME
	// `upi41_master_r(0)/(1)`. mcu_dbb_sts faked as OBF=mcu_host_dout_oe.
	.mcu_dbb_dout      (mcu_host_dout),
	// DBBSTS exposure 2026-05-30: real STATUS reg (sts/f1/f0/IBF/OBF) from the i8041 core —
	// was faked as {6'b0,IBF=0,OBF=host_dout_oe}. Needed for the BIOS<->MCU tape handshake.
	.mcu_dbb_sts       (mcu_host_sts),
	.mcu_status_d0     (mcu_p2_out[0])
);

// Tie legacy `dongle_din_low4` to the low nibble of the 8-bit output
// (mcu_tape_iface still uses dongle_din_low4 for its cpu_din formula).
assign dongle_din_low4 = dongle_din_full[3:0];

// DONGLE BYPASS FIX 2026-05-30: the $E5xx read must go through the dongle on the DATA path.
// MAME decocass_e5xx_r: (offset & E5XX_MASK)==2 -> composite STATUS byte; else -> m_dongle_r(offset).
// e5xx_dongle (from mcu_tape_iface) already returns the correct STATUS byte for cpu_addr[1]==1, so
// keep it there; route cpu_addr[1]==0 (DATA) through dongle_mux's dongle_din_full (nodong/type1/
// type3 each handle their A0 split internally). Was: decocass.v fed raw e5xx_dongle, dongle ignored.
// OBF-GATE-2026-06-08: PROPER reset fix (replaces the E500-ZERO-TEST viability hack). PROVEN this session:
// the post-load $0582 check (lda $e500/cmp#0/bne→jmp$F000) reads $E500=$0E, and $0E == mcu_host_sts (the
// 8041 STATUS reg) with OBF=0 — i.e. the read is handing back STATUS, not a fresh DBBOUT byte, because the
// 8041 is IDLE (no output pending). MAME reads 0 there. FIX: $E500 (the MCU DATA reg, cpu_addr[1]==0) is
// only valid when the 8041 has actually pushed a fresh byte out => OBF (mcu_host_sts[0]) = 1; when OBF=0
// (idle, incl. the $0582 check) read 0. Block-load bytes are UNAFFECTED — each is read with OBF=1 (the
// 8041 OUT-DBB's then handshakes via REQ). This drops the rt_seen05E2 game-PC dependency and matches MAME's
// idle $E500=0. ⚠️ CONFIDENCE: MODERATE — assumes OBF still reads 1 when the 6502 samples cpu_din (OBF
// clears on the read's trailing edge). If the LOAD regresses (blocks read as 0), revert to E500-ZERO-TEST
// (proven to boot). DIAG-REVERT-2026-06-08: prior versions below, uncomment one to restore.
// assign e5xx_to_cpu = cpu_addr[1] ? e5xx_dongle : dongle_din_full;                       // pre-fix (raw)
// assign e5xx_to_cpu = (rt_seen05E2 && cpu_addr[1:0] == 2'b00) ? 8'h00                     // E500-ZERO-TEST (proven boot)
//                    : (cpu_addr[1] ? e5xx_dongle : dongle_din_full);
// E5XX-STATUS-ROUTING-FIX-2026-06-10: MAME decocass_e5xx_r returns the 8041/tape STATUS for $E5x2/3 on ALL dongle
// types incl. Darksoft (darksoft_r is the ELSE branch = offset 0/1 only; decocass_m.cpp:1200,1229). The "darksoft
// owns ALL $E5xx" bypass returned 0xFF for $E5x2/3 — boots the menu but STARVES the game LOAD (which polls $E5x2/3
// for REQ/EOT/ERR). Route STATUS to ALL types; dongle only on $E5x0/1. Half-fix/half-experiment: if the MENU
// regresses, that pins the real bug on our 8041 Darksoft STATUS — the SAME status path as the cassette block-15 freeze.
// DIAG-REVERT-2026-06-10: bypass below, uncomment to restore the menu-booting state:
// assign e5xx_to_cpu = (dongle_type == 4'd7) ? dongle_din_full
//                    : cpu_addr[1] ? e5xx_dongle
//                    : (mcu_host_sts[0] ? dongle_din_full : 8'h00);
// DONGLE-DATA-UNGATE-2026-06-27: MAME decocass_e5xx_r (decocass_m.cpp:1227-1232) returns m_dongle_r(offset)
// for $E5x0/1 on ALL dongle types — NO OBF / 8041-status gate. The OBF gate below forced $E5x0/1 to 0x00
// whenever OBF=0, which holds throughout type3 PROM-mode reads (data = m_donglerom[ctr], decocass_m.cpp:630,
// independent of the 8041) → BurgerTime's decrypt stream read back as 0x00 = garbage. Ungated now, matching
// the darksoft path and MAME. RISK: the $0582 idle check wants $E500==0 at idle; if it reboot-loops, the next
// bug is the 8041 idle DBBOUT value (oracle = Useful Information/cbtime-e500.hex / clocknch-e500.hex), NOT this gate.
// DIAG-REVERT-2026-06-27: original OBF-gated assign commented below — restore by uncommenting it + deleting the new one.
// assign e5xx_to_cpu = cpu_addr[1] ? e5xx_dongle                           // $E5x2/3 = STATUS byte, ALL types (MAME)
//                    : (dongle_type == 4'd7) ? dongle_din_full             // $E5x0/1 = Darksoft dongle (raw)
//                    : (mcu_host_sts[0] ? dongle_din_full : 8'h00);        // $E5x0/1 = legacy OBF-gated 8041 data
assign e5xx_to_cpu = cpu_addr[1] ? e5xx_dongle                           // $E5x2/3 = STATUS byte, ALL types (MAME)
                   : dongle_din_full;                                    // $E5x0/1 = dongle data, ALL types UNGATED (MAME m_dongle_r)

// The two supported Type-3 games use a 4 KB dongle PROM. Keep it in local
// dual-port block RAM instead of the source core's general 1 MB SDRAM path.
dpram #(.address_width(12), .data_width(8)) u_dongle_prom (
  .clock_a   ( clk_sys                  ),
  .enable_a  ( 1'b1                     ),
  .address_a ( dongleprom_addr[11:0]    ),
  .data_a    ( dongleprom_dout          ),
  .wren_a    ( dongleprom_we            ),
  .q_a       (                          ),
  .clock_b   ( clk_sys                  ),
  .enable_b  ( 1'b1                     ),
  .address_b ( dprom_addr               ),
  .data_b    ( 8'h00                    ),
  .wren_b    ( 1'b0                     ),
  .q_b       ( dprom_q                  )
);

// Input polarity and bit layout are the MAME decocass IN0/IN1/IN2 maps.
wire [7:0] input_q;
wire [7:0] in0 = {2'b00, ~p1[5:0]};
wire [7:0] in1 = {2'b00, ~p2[5:0]};
wire [7:0] in2 = {p3[0], p3[1], 1'b0, ~p3[3], ~p3[2], 3'b000};
wire quadrature_latch = cpu_we_e4xx &&
                        ((cpu_addr == 16'he415) || (cpu_addr == 16'he416));
decocass_inputs decocass_inputs_inst (
  .clk_sys          ( clk_sys          ),
  .reset            ( reset            ),
  .quadrature_latch ( quadrature_latch ),
  .cpu_addr_lo      ( cpu_addr[7:0]    ),
  .in0              ( in0              ),
  .in1              ( in1              ),
  .in2              ( in2              ),
  .input_q          ( input_q          )
);

reg video_vblank_d;
always @(posedge clk_sys) begin
  if (reset)
    video_vblank_d <= 1'b1;
  else if (ce_pix)
    video_vblank_d <= video_vblank;
end
wire vblank_start = ce_pix && video_vblank && !video_vblank_d;

decocass_watchdog decocass_watchdog_inst (
  .clk_sys        ( clk_sys                                  ),
  .reset          ( reset                                    ),
  .vblank_start   ( vblank_start & ~pause_cpu                ),
  .count_w        ( cpu_we_e3xx && cpu_addr == 16'he300     ),
  .flip_w         ( cpu_we_e3xx && cpu_addr == 16'he301     ),
  .cpu_dout       ( cpu_dout                                 ),
  .dsw1           ( dsw1                                     ),
  .watchdog_reset ( watchdog_reset                           ),
  .flip_screen    ( flip_screen                              )
);

// =========================================================================
// AUDIO CPU (task 12)
// =========================================================================
wire        ay1_data_we, ay1_addr_we, ay2_data_we, ay2_addr_we;
wire [7:0]  ay_data_out;

// Sound latch ↔ audio CPU glue wires
wire        audio_to_main_we;
wire        audio_from_main_re;
wire [7:0]  audio_to_main_data;
wire [7:0]  main_to_audio_data;
wire        audio_irq;

// The reference audio helper exposes the live T65 address bus through its
// legacy `dbg_pc` port. It is the exact address needed for MAME's any-access
// $1800-$1fff response-ACK window; it is not merely the instruction PC.
wire [15:0] aud_bus_addr;

audio_cpu audio_cpu_inst (
	.clk_sys      (clk_sys),
	.ce_audio     (ce_audio),
	.reset        (reset | subsystem_reset[0]),
	.ce_pix       (ce_pix),
	.audio_irq_set(audio_irq),
	.hcounter_eq_0(hcnt == 9'h000),
	.vcounter     (vcnt),
	.rom_we       (abios_we_rom),
	.rom_addr_w   (abios_addr_rom),
	.rom_data_w   (abios_dout_rom),
	.ay1_data_we  (ay1_data_we),
	.ay1_addr_we  (ay1_addr_we),
	.ay2_data_we  (ay2_data_we),
	.ay2_addr_we  (ay2_addr_we),
	.ay_data_out  (ay_data_out),
	.sound_to_main_we(audio_to_main_we),
	.sound_from_main_re(audio_from_main_re),
	.sound_to_main(audio_to_main_data),
	.sound_from_main(main_to_audio_data),
	// The source audio block retains this legacy port but correctly ignores it.
	// MAME enables audio NMI from audio-CPU accesses at $1000-$17ff; main-CPU
	// $E416 is the quadrature-latch write handled by decocass_inputs.
	.audio_nmi_master_enable(1'b0),
	.dbg_pc      (aud_bus_addr),
	.dbg_sync    (),
	.dbg_nmi_n   (),
	.dbg_nmi_en  ()
);

// =========================================================================
// SOUND LATCHES (task 14) — $E414, $E700, $E701
// =========================================================================
wire [7:0]  sound_data, sound_ack;

decocass_sound_latches decocass_sound_latches_inst (
	.clk_sys       (clk_sys),
	.reset         (reset),
	.main_we_e414  (cpu_we_e414),
	.main_dout     (cpu_dout),
	.main_din_e700 (sound_data),
	.main_din_e701 (sound_ack),
	.audio_we_c000 (audio_to_main_we),
	.audio_re_a000 (audio_from_main_re),
	.audio_ack_reset(aud_bus_addr[15:11] == 5'b00011),
	.audio_dout    (audio_to_main_data),
	.audio_din_a000(main_to_audio_data),
	.audio_irq     (audio_irq)
);

// =========================================================================
// AY-3-8910 PAIR (task 13)
// =========================================================================
wire signed [15:0] ay_mono;

// One strobe per scanline (~15.6 kHz) for the AY DC blocker. jt49_dcrm2's
// corner is f_cen/(2*pi*1024): ~2.4 Hz here versus ~233 Hz on ce_hclk2, which
// removed the bass. Derived combinationally from the existing raster counter.
wire ce_line_dc = ce_hclk_raw && (hcnt == 9'd383);

ay8910_pair ay8910_pair_inst (
	.clk_sys      (clk_sys),
	.ce_hclk2     (ce_hclk2),
	.ce_dc        (ce_line_dc),
	.ce_audio     (ce_audio),
	.reset        (reset),
	.ay1_data_we  (ay1_data_we),
	.ay1_addr_we  (ay1_addr_we),
	.ay2_data_we  (ay2_data_we),
	.ay2_addr_we  (ay2_addr_we),
	.audio_dout   (ay_data_out),
	.sound_out    (ay_mono),
	.dbg_ay_pulse ()
);

// =========================================================================
// VIDEO SUBSYSTEM (tasks 07-11)
// =========================================================================
wire [4:0]  fg_pen, spr_pen, mis_pen;
wire [5:0]  bg_pen;   // PALETTE-BG-COLORSET-2026-06-28: 6-bit (BG color-set 5 reaches pens 40-47, the upper/bitswapped half)
wire        fg_opaque, bg_opaque, spr_opaque, mis_opaque;

// Video timing
video_timing video_timing_inst (
	.clk_sys      (clk_sys),
	.ce_pix       (ce_pix),
	.reset        (reset),
	.hsync        (video_hsync),
	.vsync        (video_vsync),
	.hblank       (video_hblank),
	.vblank       (video_vblank),
	.hcnt         (hcnt),
	.vcnt         (vcnt),
	.vsync_pulse  ()
);

// FG tilemap (task 08)
video_fg video_fg_inst (
	.clk_sys           (clk_sys),
	.ce_pix            (ce_pix),
	.hcnt              (hcnt),
	.vcnt              (vcnt),
	.cpu_we_fg         (cpu_we_fgvram),
	.cpu_we_col        (cpu_we_colram),
	.cpu_we_char_p0    (charram_we_p0),
	.cpu_we_char_p1    (charram_we_p1),
	.cpu_we_char_p2    (charram_we_p2),
	.cpu_addr          (cpu_addr[12:0]),       // 13-bit (covers 8 KB plane + 1 KB fg/col)
	.cpu_dout          (cpu_dout),
	.color_center_bot  (color_center_bot_reg), // $E410 — bit 0 → FG color
	.fg_pen            (fg_pen),
	.fg_opaque         (fg_opaque)
);

// BG tilemaps (task 09)
video_bg video_bg_inst (
	.clk_sys           (clk_sys),
	.ce_pix            (ce_pix),
	.hcnt              (hcnt),
	.vcnt              (vcnt),
	.back_h_shift      (back_h_shift_reg),
	.back_vl_shift     (back_vl_shift_reg),
	.back_vr_shift     (back_vr_shift_reg),
	.mode_set          (mode_set_reg),
	.color_center_bot  (color_center_bot_reg),
	.cpu_we_tile       (cpu_we_tilram),
	.cpu_addr_tile     (cpu_addr[10:0]),
	.cpu_dout          (cpu_dout),
	.bg_pen            (bg_pen),
	.bg_opaque         (bg_opaque)
);

// Sprites (task 10)
// SPRITE-DESC-SWIZZLE-FIX-2026-06-11: the sprite descriptor mirror must be a TRUE copy of fgvideoram, which
// applies the $C800-$CBFF mirror-swizzle (video_fg.v:71-74 / MAME mirrorvideoram_w: swap upper-5/lower-5 bits).
// Feeding the RAW cpu_addr[9:0] left the descriptor BRAM un-swizzled → mirror-region descriptor writes landed at
// the wrong address → garbage descriptors → garbage sprites (the top-right "numbers"). No-op for direct writes.
wire [9:0] spr_desc_wr_addr = cpu_addr[11] ? {cpu_addr[4:0], cpu_addr[9:5]} : cpu_addr[9:0];
decocass_video_sprites decocass_video_sprites_inst (
	.clk_sys           (clk_sys),
	.reset             (reset),
	.ce_pix            (ce_pix),
	.hcnt              (hcnt),
	.vcnt              (vcnt),
	.color_center_bot  (color_center_bot_reg),
	.cpu_we_spr        (cpu_we_fgvram),
	// SPRITE-DESC-SWIZZLE-FIX-2026-06-11: was `.cpu_spr_addr(cpu_addr[9:0])` (raw). DIAG-REVERT: restore raw.
	.cpu_spr_addr      (spr_desc_wr_addr),
	.cpu_spr_dout      (cpu_dout),
	.cpu_we_char_p0    (charram_we_p0),    // SPRITE-REWRITE-2026-06-10: charram gfx mirror (sprites share charram w/ FG)
	.cpu_we_char_p1    (charram_we_p1),
	.cpu_we_char_p2    (charram_we_p2),
	.cpu_char_addr     (cpu_addr[12:0]),
	.cpu_char_dout     (cpu_dout),
	.spr_pen           (spr_pen),
	.spr_priority      (spr_opaque)
);

// Missiles (task 10)
// MISSILES-DESC-SWIZZLE-FIX-2026-06-28: missile descriptors live in COLORRAM, which applies the same $C800
// mirror-swizzle as fgvideoram (video_fg.v write_addr_eff). The mirror was fed RAW cpu_addr[9:0] → mirror-region
// descriptor writes landed at the wrong address → garbage/off-screen missile positions → missiles invisible.
// SAME root + fix as the sprite descriptor mirror (SPRITE-DESC-SWIZZLE-FIX). No-op for direct $C4xx writes.
wire [9:0] mis_desc_wr_addr = cpu_addr[11] ? {cpu_addr[4:0], cpu_addr[9:5]} : cpu_addr[9:0];
decocass_video_missiles decocass_video_missiles_inst (
	.clk_sys           (clk_sys),
	.reset             (reset),
	.ce_pix            (ce_pix),
	.hcnt              (hcnt),
	.vcnt              (vcnt),
	.color_missiles    (color_missiles_reg),   // MISSILES-IMPL-2026-06-28: was 8'h00 (stubbed)
	.flip_screen       (flip_screen),
	.cpu_we_mis        (cpu_we_colram),
	// MISSILES-DESC-SWIZZLE-FIX-2026-06-28: was `.cpu_mis_addr(cpu_addr[9:0])` (raw). DIAG-REVERT: restore raw.
	.cpu_mis_addr      (mis_desc_wr_addr),
	.cpu_mis_dout      (cpu_dout),
	.mis_pen           (mis_pen),
	.mis_priority      (mis_opaque)
);

// Internal core RGB (8-bit each) — palette upper nibble + replicated lower
wire [3:0] core_r_hi, core_g_hi, core_b_hi;
wire [5:0] mixer_pen;

// ===== DIAG-REVERT-2026-06-03e: 8041-PC + HANDSHAKE PROBE (delete this block + restore the

// Palette lookup (task 11)
//
// 2026-05-16: WHITE-SCREEN ROOT CAUSE.
// Per MAME decocass_v.cpp:323-333 (`decocass_paletteram_w`):
//     offset = (offset & 31) ^ 16;
//     m_palette->set_indirect_color(offset, ...);
// The hardware XORs bit 4 (and mod-32s) the CPU's write offset before
// committing it to the indirect-color table that drives video output.
// Without this XOR, BIOS writes meant for pen-N color land at palette
// index N — including the critical pen-8 color (`BG_FILL` in
// video_mixer.v), which BIOS writes to $E000+24 expecting it to map
// to palette[8] via the XOR. Without the XOR, palette[8] stays at 0,
// `clut_index = palram_dout[4:0] = 0`, CLUT[0] = 12'hFFF = PURE WHITE.
// Symptom: hours of "white screen, can't get past it." The audio-hijack
// rounds proved BIOS was writing real non-zero data; the writes just
// went to the wrong addresses. Now applying the XOR on the address that
// reaches the video palette read-side dpram.
video_palette video_palette_inst (
	.clk_sys      (clk_sys),
	.ce_pix       (ce_pix),
	.cpu_we       (cpu_we_palram),
	.cpu_addr     ({3'b000, cpu_addr[4:0] ^ 5'b10000}),
	.cpu_dout     (cpu_dout),
	.pen          (mixer_pen),
	.prom_index   (5'h00),
	.red          (core_r_hi),
	.grn          (core_g_hi),
	.blu          (core_b_hi)
);

// Mixer: priority encoding + layer blending (task 11)

decocass_video_mixer decocass_video_mixer_inst (
	.clk_sys                (clk_sys),
	.ce_pix                 (ce_pix),
	.fg_pen                 (fg_pen),
	.fg_opaque              (fg_opaque),
	.bg_pen                 (bg_pen),
	.bg_opaque              (bg_opaque),
	.spr_pen                (spr_pen),
	.spr_opaque             (spr_opaque),
	.mis_pen                (mis_pen),
	.mis_opaque             (mis_opaque),
	.mode_set               (mode_set_reg),
	.color_center_bot       (color_center_bot_reg),
	.color_missiles         (color_missiles_reg),   // MISSILES-IMPL-2026-06-28: was 8'h00 (stubbed)
	.back_h_shift           (back_h_shift_reg),
	.back_vl_shift          (back_vl_shift_reg),
	.back_vr_shift          (back_vr_shift_reg),
	.part_h_shift           (part_h_shift_reg),
	.part_v_shift           (part_v_shift_reg),
	.center_h_shift_space   (center_h_shift_space_reg),
	.center_v_shift         (center_v_shift_reg),
	.hcnt                   (hcnt),
	.vcnt                   (vcnt),
	.object_addr            (objram_addr_gfx),
	.object_data            (objram_q_gfx),
	.out_pen                (mixer_pen),
	.out_pen_b4_modulate    ()
);


// Align blanking/sync to the RGB pipeline. The blank-referenced capture
// against MAME 0.289 showed RGB three pixels later than the old four-pixel
// delay assumed (content shifted right, last columns clipped), so the
// measured pipeline is seven pixels.
localparam [4:0] VID_HV_DELAY = 5'd7;
reg [15:0] hbl_sr = 16'hffff;
reg [15:0] vbl_sr = 16'hffff;
reg [15:0] hs_sr  = 16'h0000;
reg [15:0] vs_sr  = 16'h0000;
always @(posedge clk_sys) if (ce_pix) begin
  if (reset) begin
    hbl_sr <= 16'hffff;
    vbl_sr <= 16'hffff;
    hs_sr  <= 16'h0000;
    vs_sr  <= 16'h0000;
  end else begin
    hbl_sr <= {hbl_sr[14:0], video_hblank};
    vbl_sr <= {vbl_sr[14:0], video_vblank};
    hs_sr  <= {hs_sr[14:0],  video_hsync};
    vs_sr  <= {vs_sr[14:0],  video_vsync};
  end
end

assign red   = core_r_hi;
assign green = core_g_hi;
assign blue  = core_b_hi;
assign hb = hbl_sr[VID_HV_DELAY-1];
assign vb = vbl_sr[VID_HV_DELAY-1];
assign hs = hs_sr[VID_HV_DELAY-1];
assign vs = vs_sr[VID_HV_DELAY-1];
assign audio_l = ay_mono;
assign audio_r = ay_mono;
assign tape_active = tape_motor_on;

endmodule
