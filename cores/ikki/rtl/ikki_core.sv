//============================================================================
// Ikki game core — dual Z80 + SN76489A x2 + video + BRAM ROMs.
//
// This module holds the entire game.  It is instantiated by:
//   * rtl/ikki_top.sv        — the synthesis wrapper (adds SDRAM pin handling)
//   * verif/ikki_sim_top.sv  — the Verilator wrapper
//
// Both wrappers must stay thin; anything that affects behaviour belongs here so
// that simulation and synthesis cannot drift apart.
//============================================================================
module ikki_core
(
	input         clk_sys,
	input         clk_vid,
	input         reset,

	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input   [7:0] ioctl_index,

	input  [15:0] joystick_0,
	input  [15:0] joystick_1,
	input   [7:0] dip_sw1,
	input   [7:0] dip_sw2,
	input         pause,

	output        ce_pix,
	output  [3:0] r,
	output  [3:0] g,
	output  [3:0] b,
	output        hs,
	output        vs,
	output        hblank,
	output        vblank,

	output signed [15:0] audio_l,
	output signed [15:0] audio_r,

	// Diagnostics — used by the testbenches, unconnected in synthesis.
	output        spr_overflow
);

// Exact arcade rates from one 40 MHz core clock:
// pixel 5 MHz, both Z80s 4 MHz, SN1 2 MHz, SN2 4 MHz.
reg [2:0] pix_div;
always @(posedge clk_vid) begin
	if (reset) pix_div <= 0;
	else begin
		if (pix_div == 3'd7) pix_div <= 0;
		else pix_div <= pix_div + 1'd1;
	end
end
assign ce_pix = (pix_div == 0);

reg [3:0] cpu_div;
always @(posedge clk_sys) begin
	if (reset) cpu_div <= 0;
	else cpu_div <= (cpu_div == 4'd9) ? 4'd0 : cpu_div + 1'd1;
end
wire ce_cpu = (cpu_div == 0);

reg [4:0] sn1_div;
reg [3:0] sn2_div;
always @(posedge clk_sys) begin
	if (reset) begin
		sn1_div <= 0;
		sn2_div <= 0;
	end else begin
		sn1_div <= (sn1_div == 5'd19) ? 5'd0 : sn1_div + 1'd1;
		sn2_div <= (sn2_div == 4'd9)  ? 4'd0 : sn2_div + 1'd1;
	end
end
wire ce_sn1 = (sn1_div == 0);
wire ce_sn2 = (sn2_div == 0);

wire rom_download = ioctl_download && (ioctl_index == 8'd0);

// Scanlines the interrupt timer fires on, matching MAME's ikki_state::irq.
localparam [8:0] VB_START_LINE = 9'd240;
localparam [8:0] MID_LINE      = 9'd120;

// ---- ROM ----
wire [15:0] main_rom_addr;
wire [12:0] sub_rom_addr;
wire [15:0] tile_addr, sprite_addr;
wire  [9:0] lut_addr;
wire  [7:0] pal_addr;
wire  [7:0] pal_r_q, pal_g_q, pal_b_q, lut_q;
wire [8:0]  attr_addr;
wire [7:0]  main_rom_q, sub_rom_q, tile_q, sprite_q, attr_q;
wire [5:0]  spr_trans_addr;
wire [7:0]  spr_trans_q;

ikki_rom u_rom
(
	.clk_sys(clk_sys),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_download(rom_download),
	.main_addr(main_rom_addr),
	.main_q(main_rom_q),
	.sub_addr(sub_rom_addr),
	.sub_q(sub_rom_q),
	.gfx_clk(clk_vid),
	.sprite_addr(sprite_addr),
	.sprite_q(sprite_q),
	.tile_addr(tile_addr),
	.tile_q(tile_q),
	.lut_addr(lut_addr),
	.lut_q(lut_q),
	.pal_addr(pal_addr),
	.pal_r_q(pal_r_q),
	.pal_g_q(pal_g_q),
	.pal_b_q(pal_b_q),
	.attr_addr(attr_addr),
	.attr_q(attr_q),
	.spr_trans_addr(spr_trans_addr),
	.spr_trans_q(spr_trans_q)
);

// ---- Shared / VRAM / Sprite RAM ----
wire [10:0] main_shared_a, sub_shared_a, vid_vram_a, main_vram_a;
wire [10:0] sub_spr_a, vid_spr_a;
wire [7:0]  main_shared_d, sub_shared_d, main_vram_d, sub_spr_d;
wire [7:0]  main_shared_q, sub_shared_q, main_vram_q, vid_vram_q;
wire [7:0]  sub_spr_q, vid_spr_q;
wire        main_shared_we, sub_shared_we, main_vram_we, sub_spr_we;
wire        main_shared_req, sub_shared_req, sub_wait;

ikki_shared u_shared
(
	.clk(clk_sys),
	.reset(reset),
	.main_addr(main_shared_a),
	.main_din(main_shared_d),
	.main_dout(main_shared_q),
	.main_we(main_shared_we),
	.main_req(main_shared_req),
	.sub_addr(sub_shared_a),
	.sub_din(sub_shared_d),
	.sub_dout(sub_shared_q),
	.sub_we(sub_shared_we),
	.sub_req(sub_shared_req),
	.sub_wait(sub_wait)
);

ikki_dpram #(.ADDR_WIDTH(11), .REGISTERED_B(1)) u_vram
(
	.clock_a(clk_sys), .clock_b(clk_vid),
	.address_a(main_vram_a), .address_b(vid_vram_a),
	.data_a(main_vram_d), .data_b(8'h00),
	.wren_a(main_vram_we), .wren_b(1'b0),
	.q_a(main_vram_q), .q_b(vid_vram_q)
);

ikki_dpram #(.ADDR_WIDTH(11), .REGISTERED_B(1)) u_spr
(
	.clock_a(clk_sys), .clock_b(clk_vid),
	.address_a(sub_spr_a), .address_b(vid_spr_a),
	.data_a(sub_spr_d), .data_b(8'h00),
	.wren_a(sub_spr_we), .wren_b(1'b0),
	.q_a(sub_spr_q), .q_b(vid_spr_q)
);

// ---- Controls (MAME active-high) ----
wire [7:0] p1 = {
	1'b0, 1'b0, 1'b0,
	joystick_0[4], // button1
	joystick_0[2], // down
	joystick_0[3], // up
	joystick_0[1], // left
	joystick_0[0]  // right
};
wire [7:0] p2 = {
	1'b0, 1'b0, 1'b0,
	joystick_1[4],
	joystick_1[2],
	joystick_1[3],
	joystick_1[1],
	joystick_1[0]
};
wire [7:0] system = {
	joystick_0[9] | joystick_1[9], // service
	3'b000,
	joystick_0[6] | joystick_1[6] | joystick_1[7], // start2
	joystick_0[7], // start1
	joystick_1[8], // coin2
	joystick_0[8]  // coin1
};

// ---- Video ----
wire flipscreen;
wire [7:0] scroll_y, scroll_x;
wire irq_vblank, irq_mid;
wire [8:0] vcnt;

wire [15:0] tile_addr_v, sprite_addr_v;
wire [8:0]  attr_addr_v;

ikki_video u_video
(
	.clk(clk_vid),
	.reset(reset),
	.ce_pix(ce_pix),
	.flipscreen(flipscreen),
	.scroll_y(scroll_y),
	.scroll_x(scroll_x),
	.vram_addr(vid_vram_a),
	.vram_q(vid_vram_q),
	.spr_addr(vid_spr_a),
	.spr_q(vid_spr_q),
	.spr_wr_stb(sub_spr_we),
	.tile_addr(tile_addr_v),
	.tile_q(tile_q),
	.sprite_addr(sprite_addr_v),
	.sprite_q(sprite_q),
	.lut_addr(lut_addr),
	.lut_q(lut_q),
	.pal_addr(pal_addr),
	.pal_r_q(pal_r_q),
	.pal_g_q(pal_g_q),
	.pal_b_q(pal_b_q),
	.attr_addr(attr_addr_v),
	.attr_q(attr_q),
	.spr_trans_addr(spr_trans_addr),
	.spr_trans_q(spr_trans_q),
	.hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
	.r(r), .g(g), .b(b),
	.hcnt_o(),
	.vcnt_o(vcnt),
	.irq_vblank(irq_vblank),
	.irq_mid(irq_mid),
	.spr_overflow(spr_overflow)
);

assign tile_addr   = tile_addr_v;
assign sprite_addr = sprite_addr_v;
assign attr_addr   = attr_addr_v;

// ---- IRQ: MAME HOLD_LINE — hold INT until Z80 IACK (M1 & IORQ) ----
wire main_m1_n, main_iorq_n, sub_m1_n, sub_iorq_n;
wire main_iack = ~main_m1_n & ~main_iorq_n;
wire sub_iack  = ~sub_m1_n  & ~sub_iorq_n;

// One interrupt source for both CPUs.
//
// MAME drives these separately: the main CPU from a scanline timer at 120 and
// 240, the sub CPU from a free-running attotime::from_hz(2 * VSync) that is not
// locked to the display at all.  Its own driver header lists "understand proper
// CPU communications and irq firing" as an open TODO, and the sister driver
// markham.cpp -- same Sun Electronics dual-Z80 family, which ikki.cpp says it
// should be merged with -- is explicit about the consequences:
//
//     // same as Ikki, whereas if non-vblank IRQ isn't in-sync with slave CPU
//     // irqs then stage 2/3 lacks any sprite whatsoever.
//     // TODO: maybe this is just a timer device that dispatches irqs to both
//     //       CPUs and running at VSync*2. Verify on real HW or schematics.
//
// So the failure mode of getting this wrong is missing or corrupted sprites,
// and the hypothesised hardware is a single timer at 2x VSync feeding both
// CPUs.  This core previously had them unsynced *and* on different scanlines
// from MAME (sub at 0 and 131), which showed up as sprite RAM tracking MAME
// exactly for 17 frames of gameplay and then drifting.
//
// Note this deliberately diverges from MAME, which models them unsynced.
// See docs/ACCURACY_PLAN.md.
localparam SYNC_SUB_IRQ = 1;

reg irq_vblank_d, irq_mid_d;
reg [8:0] vcnt_s, vcnt_s2;
reg       sub_irq_tick;

always @(posedge clk_sys) begin
	irq_vblank_d <= irq_vblank;
	irq_mid_d    <= irq_mid;
	vcnt_s  <= vcnt;
	vcnt_s2 <= vcnt_s;
	if (SYNC_SUB_IRQ)
		// same instants as the main CPU: one timer, both CPUs
		sub_irq_tick <= (vcnt_s != vcnt_s2) &&
		                (vcnt_s == VB_START_LINE || vcnt_s == MID_LINE);
	else
		// MAME's model: free-running, unlocked from the main CPU
		sub_irq_tick <= (vcnt_s != vcnt_s2) &&
		                (vcnt_s == 9'd0 || vcnt_s == 9'd131);
end

wire irq_vblank_edge = irq_vblank & ~irq_vblank_d;
wire irq_mid_edge    = irq_mid    & ~irq_mid_d;

reg main_irq_n, sub_irq_n;
reg irq_source;

always @(posedge clk_sys) begin
	if (reset) begin
		main_irq_n <= 1'b1;
		sub_irq_n  <= 1'b1;
		irq_source <= 1'b0;
	end else begin
		if (irq_vblank_edge) begin
			main_irq_n <= 1'b0;
			irq_source <= 1'b0;
		end else if (irq_mid_edge) begin
			main_irq_n <= 1'b0;
			irq_source <= 1'b1;
		end else if (main_iack)
			main_irq_n <= 1'b1;

		if (sub_irq_tick)
			sub_irq_n <= 1'b0;
		else if (sub_iack)
			sub_irq_n <= 1'b1;
	end
end

// ---- CPUs ----
wire signed [15:0] audio;

ikki_main u_main
(
	.clk(clk_sys),
	.reset(reset),
	.ce_cpu(ce_cpu),
	.pause(pause),
	.irq_n(main_irq_n),
	.irq_source(irq_source),
	.m1_n(main_m1_n),
	.iorq_n(main_iorq_n),
	.rom_q(main_rom_q),
	.rom_addr(main_rom_addr),
	.shared_addr(main_shared_a),
	.shared_din(main_shared_d),
	.shared_dout(main_shared_q),
	.shared_we(main_shared_we),
	.shared_req(main_shared_req),
	.vram_addr(main_vram_a),
	.vram_din(main_vram_d),
	.vram_dout(main_vram_q),
	.vram_we(main_vram_we),
	.dsw1(dip_sw1),
	.dsw2(dip_sw2),
	.system(system),
	.p1(p1),
	.p2(p2),
	.flipscreen(flipscreen),
	.scroll_y(scroll_y),
	.scroll_x(scroll_x),
	.coin_cnt()
);

ikki_sub u_sub
(
	.clk(clk_sys),
	.reset(reset),
	.ce_cpu(ce_cpu),
	.ce_sn1(ce_sn1),
	.ce_sn2(ce_sn2),
	.pause(pause),
	.wait_n(~sub_wait),
	.irq_n(sub_irq_n),
	.m1_n(sub_m1_n),
	.iorq_n(sub_iorq_n),
	.rom_q(sub_rom_q),
	.rom_addr(sub_rom_addr),
	.spr_addr(sub_spr_a),
	.spr_din(sub_spr_d),
	.spr_dout(sub_spr_q),
	.spr_we(sub_spr_we),
	.shared_addr(sub_shared_a),
	.shared_din(sub_shared_d),
	.shared_dout(sub_shared_q),
	.shared_we(sub_shared_we),
	.shared_req(sub_shared_req),
	.audio(audio)
);

// Mute on pause / ioctl-driven reset (CPUs already halted by pause/reset)
assign audio_l = (pause | reset) ? 16'sd0 : audio;
assign audio_r = (pause | reset) ? 16'sd0 : audio;

endmodule
