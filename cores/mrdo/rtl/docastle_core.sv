//============================================================================
// Mr. Do's Castle complete board-level core.
//============================================================================
module docastle_core
(
	input         clk,
	input         reset,
	input         pause,
	input         pcb_fidelity,
	input         pcb_audio_filter,
	input         pcb_framebuffer,
	input         pcb_cursor_irq,
	// Simulation/verification hook. Hardware keeps the measured /10 raster
	// divider; the live RTL-vs-MAME harness selects the exact crystal ratio.
	input         exact_pixel_clock,

	input         ioctl_download,
	input         ioctl_wr,
	input   [7:0] ioctl_index,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,

	input   [7:0] dsw1,
	input   [7:0] dsw2,
	input   [7:0] joys,
	input   [7:0] joys2,
	input   [7:0] buttons,
	input   [7:0] system,

	output        ce_pix,
	output  [7:0] r,
	output  [7:0] g,
	output  [7:0] b,
	output        hs,
	output        vs,
	output        hblank,
	output        vblank,
	output signed [15:0] audio,

	output [15:0] main_pc_debug,
	output [15:0] sub_pc_debug,
	output [15:0] sprite_pc_debug,
	output        main_wait_debug,
	output  [3:0] psg_ready_debug,
	output        renderer_busy_debug,
	output        renderer_overrun_debug,
	output  [7:0] game_id_debug,
	output  [1:0] profile_debug,
	output        profile_valid_debug,
	output        adpcm_busy_debug,
	output [17:0] adpcm_nibble_debug,
	output        adpcm_strobe_debug,
	output        watchdog_reset_debug,
	output        sprite_copy_debug,
	output        cf_write_debug,
	output        cf_irq_debug,
	output        cf_overrun_debug,
	output  [7:0] cf_reg2_debug,
	output [10:0] cf_addr_debug,
	output  [7:0] cf_data_debug,
	output        crtc_write_debug,
	output  [4:0] crtc_reg_debug,
	output  [7:0] crtc_data_debug,
	output        crtc_cursor_debug
);

reg [7:0] game_id = 8'h00;
reg game_id_loaded = 1'b0;
always @(posedge clk) begin
	if (ioctl_download && (ioctl_index == 8'd0))
		game_id_loaded <= 1'b0;
	if (ioctl_download && ioctl_wr && (ioctl_index == 8'd1) && (ioctl_addr == 0)) begin
		game_id <= ioctl_dout;
		game_id_loaded <= 1'b1;
	end
end

wire profile_valid;
wire [1:0] profile;
wire low_pen_priority;
wire soccer_sprites;
wire has_adpcm;
wire has_joys2;
wire native_vertical;
docastle_profile profile_decode
(
	.game_id(game_id),
	.valid(profile_valid),
	.profile(profile),
	.low_pen_priority(low_pen_priority),
	.soccer_sprites(soccer_sprites),
	.has_adpcm(has_adpcm),
	.has_joys2(has_joys2),
	.native_vertical(native_vertical)
);

wire base_reset = reset | !profile_valid | !game_id_loaded;
reg [23:0] watchdog_count;
reg watchdog_reset;
wire watchdog_kick;
wire machine_reset_raw = base_reset | watchdog_reset;
wire machine_reset;

jtframe_rst_sync u_rst_sync (
	.rst      ( machine_reset_raw ),
	.clk      ( clk               ),
	.rst_sync ( machine_reset     )
);
assign watchdog_reset_debug = watchdog_reset;
always @(posedge clk) begin
	watchdog_reset <= 0;
	if (base_reset || pause || !pcb_fidelity || watchdog_kick)
		watchdog_count <= 0;
	else if (ce_cpu) begin
		if (watchdog_count >= 24'd11999999) begin
			watchdog_count <= 0;
			watchdog_reset <= 1;
		end else watchdog_count <= watchdog_count + 1'd1;
	end
end
assign game_id_debug = game_id;
assign profile_debug = profile;
assign profile_valid_debug = profile_valid & game_id_loaded;

// The inherited PLL provides 49.152 MHz. Keep the video enable on a fixed
// cadence: a fractional pixel accumulator has the right average frequency
// but produces 10/11-clock line-length modulation that is visible as shimmer
// on an analog CRT. /10 is 4.9152 MHz, only 0.0244% above the nominal 4.914
// MHz raster clock, and gives HSYNC a deterministic edge-to-edge period.
// CPU/PSG timing remains rational because those devices are not the analog
// sync source.
reg [3:0] pix_div;
reg [12:0] pix_phase;
reg ce_pix_r;
wire ce_mclk;
wire ce_cpu;
assign ce_pix = ce_pix_r;

// jtframe_frac_cen's toggle[W-2:0]/toggle_b[W-2:0] concatenation is only
// well-formed for W>=2 (W=1 produces an out-of-range [-1:0] slice, flagged
// by Verilator as SELRANGE/WIDTHTRUNC). jtcores' own cores never instantiate
// it below W=2 either -- e.g. cores/castle/hdl/jtcastle_sound.v uses W=4 and
// takes individual bits. Use W=2 here and take cen[0], which the module
// always drives with the base n/m-rate pulse (`cen <= { toggle[W-2:0], 1'b1
// }` -- bit 0 is unconditionally 1'b1 on every "over" event); cen[1] is an
// unused divide-by-2 subharmonic.
wire [1:0] cen_mclk_w, cen_cpu_w;
assign ce_mclk = cen_mclk_w[0];
assign ce_cpu  = cen_cpu_w[0];

// CF37201 and its external /PL counter use the 9.828 MHz MCLK, exactly
// twice the pixel rate.  9.828/49.152 = 819/4096.
jtframe_frac_cen #(.W(2),.WC(13)) u_cen_mclk (
	.clk ( clk        ),
	.n   ( 13'd819    ),
	.m   ( 13'd4096   ),
	.cen ( cen_mclk_w ),
	.cenb(            )
);

jtframe_frac_cen #(.W(2),.WC(11)) u_cen_cpu (
	.clk ( clk       ),
	.n   ( 11'd125   ),
	.m   ( 11'd1536  ),
	.cen ( cen_cpu_w ),
	.cenb(           )
);

always @(posedge clk) begin
	if (machine_reset) begin
		pix_div <= 0;
		pix_phase <= 0;
		ce_pix_r <= 0;
	end else begin
		ce_pix_r <= 0;
		if (exact_pixel_clock) begin
			// 4.914 MHz / 49.152 MHz = 819/8192. The resulting 10/11
			// master-clock cadence is selected only by simulation.
			if (pix_phase >= 13'd7373) begin
				pix_phase <= pix_phase - 13'd7373;
				ce_pix_r <= 1;
			end else pix_phase <= pix_phase + 13'd819;
		end else if (pix_div == 4'd9) begin
			pix_div <= 0;
			ce_pix_r <= 1;
		end else pix_div <= pix_div + 1'd1;
	end
end

// ROM ports.
wire [15:0] main_rom_addr;
wire [13:0] sub_rom_addr;
wire  [8:0] sprite_rom_addr;
wire [13:0] char_addr;
wire [16:0] sprite_gfx_addr;
wire [15:0] adpcm_rom_addr;
wire  [7:0] prom_addr;
wire [7:0] main_rom_q, sub_rom_q, sprite_rom_q, char_q, sprite_gfx_q;
wire [7:0] adpcm_rom_q, prom_q;

docastle_rom roms
(
	.*,
	.main_addr(main_rom_addr), .main_q(main_rom_q),
	.sub_addr(sub_rom_addr), .sub_q(sub_rom_q),
	.sprite_cpu_addr(sprite_rom_addr), .sprite_cpu_q(sprite_rom_q),
	.char_addr(char_addr), .char_q(char_q),
	.sprite_gfx_addr(sprite_gfx_addr), .sprite_gfx_q(sprite_gfx_q),
	.adpcm_addr(adpcm_rom_addr), .adpcm_q(adpcm_rom_q),
	.prom_addr({1'b0,prom_addr}), .prom_q(prom_q)
);

// Single bidirectional latch and main-CPU WAIT handshake.
reg [7:0] comm_latch;
reg main_wait;
wire [7:0] main_comm_dout, sub_comm_dout;
wire main_comm_start, main_comm_write;
wire sub_comm_access, sub_comm_write;
assign main_wait_debug = main_wait;

always @(posedge clk) begin
	if (machine_reset) begin
		comm_latch <= 0;
		main_wait <= 0;
	end else begin
		if (main_comm_write) comm_latch <= main_comm_dout;
		if (sub_comm_write)  comm_latch <= sub_comm_dout;
		if (main_comm_start) main_wait <= 1;
		if (sub_comm_access) main_wait <= 0;
	end
end

// Shared video RAM wiring.
wire [8:0] spr_addr;
wire [7:0] spr_din;
wire spr_we;
wire [9:0] video_addr, color_addr;
wire [7:0] video_din, color_din, video_q, color_q;
wire video_we, color_we;
wire [4:0] crtc_reg;
wire [7:0] crtc_data;
wire crtc_we;
wire sub_nmi_req;
wire flipscreen;
wire main_m1_n, main_iorq_n, sub_m1_n, sub_iorq_n;

wire main_irq_n;
wire sub_irq_req;
wire sprite_nmi_req;
wire [8:0] sprite_copy_addr;
wire [7:0] sprite_copy_data;
wire sprite_copy_we;
wire [10:0] cf_addr;
wire [7:0] cf_data;
wire cf_we, cf_irq_req, cf_irq_ack;
wire [7:0] cf_dram_addr;
wire [15:0] cf_dram_address;
wire cf_dram_strobe, cf_dram_column;
wire [7:0] cf_dram_y, cf_dram_x;
wire [4:0] cf_palette;
wire cf_flip_x, cf_flip_y, cf_plus_one, cf_serial_invert;
wire cf_busy, cf_overrun;
wire [8:0] h_count_debug_wire, v_count_debug_wire;
reg sub_irq_n;
wire sub_iack = ~sub_m1_n & ~sub_iorq_n;
wire [7:0] adpcm_status;
wire adpcm_wr;
wire [7:0] adpcm_data;
wire signed [11:0] adpcm_sound;
wire signed [15:0] psg_audio;

always @(posedge clk) begin
	if (machine_reset) sub_irq_n <= 1;
	else begin
		if (sub_iack) sub_irq_n <= 1;
		if (sub_irq_req) sub_irq_n <= 0;
	end
end

docastle_main main_cpu
(
	.clk(clk), .reset(machine_reset), .ce_cpu(ce_cpu), .pause(pause), .profile(profile),
	.irq_n(main_irq_n), .rom_q(main_rom_q), .rom_addr(main_rom_addr),
	.comm_latch(comm_latch), .comm_dout(main_comm_dout),
	.comm_start(main_comm_start), .comm_write(main_comm_write),
	.comm_wait_n(~main_wait),
	.sprite_addr(spr_addr), .sprite_din(spr_din), .sprite_we(spr_we),
	.video_addr(video_addr), .video_din(video_din), .video_dout(video_q), .video_we(video_we),
	.color_addr(color_addr), .color_din(color_din), .color_dout(color_q), .color_we(color_we),
	.adpcm_status(adpcm_status), .adpcm_wr(adpcm_wr), .adpcm_data(adpcm_data),
		.crtc_reg(crtc_reg), .crtc_data(crtc_data), .crtc_we(crtc_we),
		.sub_nmi_req(sub_nmi_req), .watchdog_kick(watchdog_kick),
	.cpu_addr_debug(main_pc_debug), .m1_n_debug(main_m1_n), .iorq_n_debug(main_iorq_n)
);

docastle_sub sub_cpu
(
	.clk(clk), .reset(machine_reset), .ce_cpu(ce_cpu), .ce_psg(ce_cpu), .pause(pause),
	.profile(profile),
	.irq_n(sub_irq_n), .nmi_req(sub_nmi_req),
	.rom_q(sub_rom_q), .rom_addr(sub_rom_addr),
	.comm_latch(comm_latch), .comm_dout(sub_comm_dout),
	.comm_access(sub_comm_access), .comm_write(sub_comm_write),
	.dsw1(dsw1), .dsw2(dsw2), .joys(joys), .joys2(joys2),
	.buttons(buttons), .system(system),
	.flipscreen(flipscreen), .audio(psg_audio),
	.cpu_addr_debug(sub_pc_debug), .m1_n_debug(sub_m1_n), .iorq_n_debug(sub_iorq_n),
	.psg_ready_debug(psg_ready_debug)
);

docastle_spritecpu sprite_cpu
(
	.clk(clk), .reset(machine_reset), .ce_cpu(ce_cpu), .pause(pause),
	.pcb_fidelity(pcb_fidelity), .nmi_req(sprite_nmi_req), .cf_irq_req(cf_irq_req),
	.main_addr(spr_addr), .main_data(spr_din), .main_we(spr_we),
	.rom_q(sprite_rom_q), .rom_addr(sprite_rom_addr),
	.copy_addr(sprite_copy_addr), .copy_data(sprite_copy_data), .copy_we(sprite_copy_we),
	.cf_addr(cf_addr), .cf_data(cf_data), .cf_we(cf_we),
	.cf_irq_ack(cf_irq_ack),
	.cpu_addr_debug(sprite_pc_debug)
);

assign sprite_copy_debug = sprite_copy_we;
assign cf_write_debug = cf_we;
assign cf_irq_debug = cf_irq_req;
assign cf_overrun_debug = cf_overrun;
assign cf_addr_debug = cf_addr;
assign cf_data_debug = cf_data;
assign crtc_write_debug = crtc_we;
assign crtc_reg_debug = crtc_reg;
assign crtc_data_debug = crtc_data;

docastle_cf37201 cf37201
(
	.clk(clk), .reset(machine_reset), .ce_mclk(ce_mclk), .bus_we(cf_we),
	.bus_addr(cf_addr[1:0]), .bus_data(cf_data),
	.frame_parity(v_count_debug_wire[0]), .irq_ack(cf_irq_ack),
	.irq_req(cf_irq_req), .dram_addr(cf_dram_addr), .dram_address(cf_dram_address),
	.dram_strobe(cf_dram_strobe), .dram_column(cf_dram_column),
	.dram_y(cf_dram_y), .dram_x(cf_dram_x), .palette(cf_palette),
	.flip_x(cf_flip_x), .flip_y(cf_flip_y), .plus_one(cf_plus_one),
	.serial_invert(cf_serial_invert), .busy(cf_busy), .overrun(cf_overrun),
	.reg2_debug(cf_reg2_debug)
);

docastle_video video
(
	.clk(clk), .reset(machine_reset), .ce_pix(ce_pix_r),
	.cursor_irq_mode(pcb_cursor_irq), .pcb_framebuffer(pcb_framebuffer), .flipscreen(flipscreen),
	.low_pen_priority(low_pen_priority), .soccer_sprites(soccer_sprites),
	.video_cpu_addr(video_addr), .video_cpu_din(video_din), .video_cpu_we(video_we), .video_cpu_q(video_q),
	.color_cpu_addr(color_addr), .color_cpu_din(color_din), .color_cpu_we(color_we), .color_cpu_q(color_q),
	.sprite_cpu_addr(spr_addr), .sprite_cpu_din(spr_din), .sprite_cpu_we(spr_we),
	.pcb_sprite_addr(cf_addr[8:0]), .pcb_sprite_din(cf_data),
	// C000-C1FF is the physical 512-byte sprite doorway.  C432 is the
	// protection/CF control latch and must never corrupt sprite RAM.
	.pcb_sprite_we(cf_we && (cf_addr < 11'h200)),
	.cf_dram_address(cf_dram_address), .cf_dram_strobe(cf_dram_strobe),
	.cf_dram_column(cf_dram_column), .cf_dram_y(cf_dram_y), .cf_dram_x(cf_dram_x),
	.cf_palette(cf_palette), .cf_flip_x(cf_flip_x), .cf_flip_y(cf_flip_y),
	.cf_plus_one(cf_plus_one), .cf_serial_invert(cf_serial_invert),
	.char_addr(char_addr), .char_q(char_q),
	.sprite_gfx_addr(sprite_gfx_addr), .sprite_gfx_q(sprite_gfx_q),
	.prom_addr(prom_addr), .prom_q(prom_q),
	.crtc_reg(crtc_reg), .crtc_data(crtc_data), .crtc_we(crtc_we),
	.r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
	.main_irq_n(main_irq_n), .sub_irq_req(sub_irq_req), .sprite_nmi_req(sprite_nmi_req),
	.h_count_debug(h_count_debug_wire), .v_count_debug(v_count_debug_wire),
	.cursor_debug(crtc_cursor_debug),
	.renderer_busy_debug(renderer_busy_debug),
	.renderer_overrun_debug(renderer_overrun_debug)
);

docastle_adpcm adpcm
(
	.clk(clk), .reset(machine_reset), .pause(pause), .enabled(has_adpcm),
	.control_wr(adpcm_wr), .control_data(adpcm_data), .status(adpcm_status),
	.rom_addr(adpcm_rom_addr), .rom_q(adpcm_rom_q), .sound(adpcm_sound),
	.busy_debug(adpcm_busy_debug), .nibble_pos_debug(adpcm_nibble_debug),
	.nibble_strobe_debug(adpcm_strobe_debug)
);

wire signed [17:0] psg_mix = {{2{psg_audio[15]}},psg_audio};
// MAME's MSM5205 stream is signal/4096, masks the low two bits for the
// physical 10-bit DAC, then routes the device at 0.40. In signed 16-bit
// output units that is a gain of 3.20. 13/4 = 3.25 is the nearest compact
// fixed-point gain and differs by only +0.135 dB.
wire signed [11:0] adpcm_dac = {adpcm_sound[11:2],2'b00};
wire signed [17:0] adpcm_scaled = $signed(adpcm_dac) * 18'sd13;
wire signed [17:0] adpcm_mix = adpcm_scaled >>> 2;
wire signed [18:0] full_mix = {psg_mix[17],psg_mix} + {adpcm_mix[17],adpcm_mix};
reg signed [15:0] mixed_audio;
always @(*) begin
	if (full_mix > 19'sd32767)
		mixed_audio = 16'sh7fff;
	else if (full_mix < -19'sd32768)
		mixed_audio = -16'sd32768;
	else
		mixed_audio = full_mix[15:0];
end
wire signed [15:0] filtered_audio;
docastle_audio_filter pcb_filter
(
	.clk(clk), .reset(machine_reset), .enable(pcb_audio_filter),
	.sample_in(mixed_audio), .sample_out(filtered_audio)
);
assign audio = (machine_reset || pause) ? 16'sd0 : filtered_audio;

wire _unused = main_m1_n | main_iorq_n | has_joys2 | native_vertical |
	|cf_dram_addr | |cf_palette | cf_flip_x | cf_flip_y | cf_plus_one |
	cf_serial_invert | cf_busy | cf_overrun;
endmodule
