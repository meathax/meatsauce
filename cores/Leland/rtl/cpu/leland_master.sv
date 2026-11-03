// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - Master Z80 CPU
//
//  Leland Master Z80 memory map (validated against MAME leland.cpp):
//    0x0000-0x1FFF  ROM fixed bank (always master_rom[0x00000..0x01FFF])
//    0x2000-0x9FFF  Banked ROM window (32 KB, bank register selects offset)
//    0xA000-0xDFFF  Fixed ROM (region offset 0xA000, unbanked) UNLESS
//                   bank_reg==1, in which case it's the battery-backed
//                   RAM view instead (see master_redline_map_program /
//                   offroad_bankswitch's update_battery_ram_view call)
//    0xE000-0xEFFF  Work RAM (4 KB, PRIVATE -- never shared with Slave;
//                   see leland_board.sv's wram_m/wram_s comment)
//    0xF000-0xF3FF  Color RAM (1 KB, palette entries BGR 2-3-3)
//    0xF800-0xF801  Video address latches (slave triggers sprite blit)
//
//  I/O port map (validated against MAME leland.cpp master_map_io and
//  redline_state::init_offroad):
//    0xF0        ROM bank register (write, bits [2:0] used)
//    0xF8        Player 3 wheel read (offroad_wheel_3_r, dial-encoded)
//    0xF9        Player 1 wheel read (offroad_wheel_1_r, dial-encoded)
//    0xFB        Player 2 wheel read (offroad_wheel_2_r, dial-encoded)
//    0xFD        Player 1 pedal read (raw, AN0)
//    0xFE        Player 2 pedal read (raw, AN1)
//    0xFF        Player 3 pedal read (raw, AN2)
//
//  Banking (validated against MAME leland_m.cpp offroad_bankswitch):
//    bank_reg [2:0] indexes a fixed lookup table of ROM base offsets.
//    The 48 KB window at 0x2000-0xDFFF maps to master_rom[bank_offset +
//    (cpu_addr - 0x2000)].  bank_list (MAME):
//      0 → 0x02000   1 → 0x02000   2 → 0x10000   3 → 0x18000
//      4 → 0x20000   5 → 0x28000   6 → 0x30000   7 → 0x38000
//============================================================================

import leland_board_pkg::*;

module leland_master
(
	input         clk_sys,
	input         reset,
	input         CE_6M,       // 6 MHz clock enable

	// Master program ROM (read-only)
	output [17:0] rom_addr,
	input   [7:0] rom_data,

	// Work RAM (4 KB, private to the master)
	output [11:0] wram_addr,   // 4 KB
	output  [7:0] wram_din,
	output        wram_we,
	input   [7:0] wram_dout,

	// Battery-backed RAM (0xA000-0xDFFF, 16 KB), master-private: normally fixed ROM (region
	// offset 0xA000), overlaid by MAME's battery_ram_view only when bank_reg == 1.
	output [13:0] battram_addr,
	output  [7:0] battram_din,
	output        battram_we,
	input   [7:0] battram_dout,

	// Color RAM — master writes palette; video reads (leland_video)
	output  [9:0] cram_addr,
	output  [7:0] cram_din,
	output        cram_we,
	input   [7:0] cram_dout,   // palette RAM read-back (port A of the color RAM)

	// VRAM I/O port op stream (to leland_board's VRAM sequencer) --
	// leland_mvram_port_r/w, installed by init_master_ports at
	// mvram_base=0x00 and 0x40 (see leland.cpp init_offroad()).
	output        vp_req,
	output        vp_rd,
	output        vp_trans,
	output [15:0] vp_addr,
	output  [7:0] vp_data,
	input         vp_pop,
	input   [7:0] vp_rdata,

	// /MCONT control outputs (I/O port 0x09, validated MAME leland_master_output_w)
	//   bit0: slave_reset_n  (0=hold Slave in reset, 1=run)
	//   bit2: slave_nmi_n    (0=assert NMI)
	//   bit3: slave_int_req  (0=assert Slave INT)
	output        slave_reset_n,
	output        slave_nmi_n,
	output        slave_int_req, // held level: asserted while /MCONT bit3=0

	// 80186 sound-board control latch: port 0xF0 is both the graphics bank register
	// (bank_reg) and the sound board's control register (/RESET, ZNMI, INT0, /TEST, INT1 in
	// bits [7:3]); MAME's redline_master_alt_bankswitch_w forwards the same byte to both.
	// sound_ctrl_wr is a one-cycle strobe on each write.
	output  [7:0] sound_ctrl_data,
	output        sound_ctrl_wr,

	// Sound command latch writes (ports 0xF2/0xF4, leland_a.cpp command_lo_w/command_hi_w).
	// cmd_wr_data replicates the byte into both halves; the sound board only uses [7:0] on
	// cmd_wr_lo and [15:8] on cmd_wr_hi.
	output [15:0] cmd_wr_data,
	output        cmd_wr_lo,
	output        cmd_wr_hi,

	// 80186 response latch (leland_sound_board response_data); port 0xF2 reads return it.
	// Same clk_sys domain, so no synchroniser is needed.
	input  [7:0]  response_data,

	// Video address latch (triggers Slave sprite blit, Chunk 3)
	output [15:0] vid_addr,
	output        vid_addr_wr,

	// Background scroll registers (MAME scroll_w at io_base+0x0C-0x0F: ports 0xCC-0xCF and
	// 0x8C-0x8F for Off-Road).
	output [15:0] scroll_x,
	output [15:0] scroll_y,

	// Graphics bank (MAME m_gfxbank / leland_video gfxbank), set through the AY-3-8910 port A
	// write callback: the ROM writes a register select (I/O 0x0A, /OGIA) then data (0x0B,
	// /OGID), relocated like /MCONT. Only register 0x0E is tracked; the rest of the AY
	// only affects audio.
	output  [7:0] gfxbank,

	// Slave HALT status (wired to GIN1 bit 0, active-low)
	input         slave_halt_n,

	// EEPROM (93C46, leland_eeprom_93c46) -- DI/CLK/CS are /MCONT bits
	// 4/5/6 (leland_master_output_w), DO feeds GIN3 bit0 above.
	output        eeprom_di,
	output        eeprom_clk,
	output        eeprom_cs,
	input         eeprom_do,

	// VBlank for GIN3 bit 1 timing sync
	input         vblank,

	// Raster line counter (from leland_video), used to generate the periodic
	// "VA10" interrupt every 16 scanlines starting at line 8 (validated
	// against MAME leland_m.cpp leland_interrupt_callback).
	input   [7:0] raster_line,

	// Pedal (MAME AN0-AN2, IPT_PEDAL): raw value, read directly at ports 0xFD/0xFE/0xFF.
	input   [7:0] p1_pedal,
	input   [7:0] p2_pedal,
	input   [7:0] p3_pedal,

	// Wheel (MAME AN3-AN5, IPT_DIAL): a free-spinning encoder, so only the direction and
	// magnitude of motion since the last read is reported (dial_compute_value). p*_wheel is
	// the free-running mod-256 virtual dial (stick + d-pad + spinner, see
	// steering_input.sv), sampled on each read.
	input   [7:0] p1_wheel,
	input   [7:0] p2_wheel,
	input   [7:0] p3_wheel,

	// Digital inputs (active-high from MiSTer)
	input   [3:0] p1_btn,      // [3]=coin [2]=btn2 [1]=btn1 [0]=btn0
	input   [3:0] p2_btn,
	input   [3:0] p3_btn,
	input         service,

	// Per-game I/O bases (leland_board_pkg::game_cfg, from the MRA header's game_id):
	// io_base/mvram_base are the leland_master_input_r/output_w and leland_mvram_port_r/w
	// window bases; dual_io_window reproduces Off-Road's double install; in4_port_en gates
	// Pig Out's fixed IN4 at 0x7F; input_scheme selects the GIN0-3 bit layout.
	input   [7:0] io_base,
	input   [7:0] mvram_base,
	input         dual_io_window,
	input         in4_port_en,
	input  leland_board_pkg::input_scheme_e input_scheme,

	// 4-player digital joystick (Pig Out only): [0]=right [1]=left [2]=down [3]=up
	// [4]=btn1 [5]=btn2 [6]=start [7]=coin.
	input   [7:0] p1_joy, p2_joy, p3_joy, p4_joy,

	// SDRAM stall: level-high during ROM read; stall when not ready
	output        rom_req,    // high during any ROM read machine cycle
	input         rom_stall  // high = SDRAM not ready; insert wait states
);

//------------------------------------------------------------------
// tv80s_ce (synchronous Z80, Verilog, with clock enable)
//------------------------------------------------------------------
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;

// int_n_final and mvport_stall are declared before the CPU instance: ModelSim infers an
// implicit net at first use in a port connection, which then conflicts with a later
// explicit declaration.
wire int_n_final;
wire mvport_stall; // from leland_vram_port: holds the CPU in /WAIT instead of overwriting
                   // a VRAM port op that has not drained yet

tv80s_ce #(.Mode(0), .T2Write(1), .IOWait(1)) master_cpu
(
	.reset_n(~reset),
	.clk    (clk_sys),
	.cen    (CE_6M),
	.wait_n (~((rom_req & rom_stall) | mvport_stall)),
	.int_n  (int_n_final),
	.nmi_n  (1'b1),
	.busrq_n(1'b1),
	.m1_n   (m1_n),
	.read_t2(),
	.mreq_n (mreq_n),
	.iorq_n (iorq_n),
	.rd_n   (rd_n),
	.wr_n   (wr_n),
	.rfsh_n (rfsh_n),
	.halt_n (halt_n),
	.busak_n(busak_n),
	.A      (cpu_addr),
	.di     (cpu_din),
	.dout   (cpu_dout)
);

//------------------------------------------------------------------
// Periodic "VA10" interrupt — validated against MAME leland_m.cpp
// leland_interrupt_callback(): fires every 16 scanlines starting at
// line 8. This is the only Master INT source in MAME.
//------------------------------------------------------------------
reg [7:0] raster_line_prev;
reg       periodic_int_n;

always @(posedge clk_sys) begin
	raster_line_prev <= raster_line;
	if (reset)
		periodic_int_n <= 1'b1;
	else if ((raster_line != raster_line_prev) && (raster_line[3:0] == 4'd8))
		periodic_int_n <= 1'b0;
	else if (CE_6M && ~iorq_n & ~m1_n)  // INT acknowledge cycle
		periodic_int_n <= 1'b1;
end

// The periodic VA10 raster interrupt is the only master INT source in MAME; the CPUs
// otherwise communicate through the shared VRAM mailbox and the SLAVEHALT/GIN1 poll
// (see leland_slave.sv).
assign int_n_final = periodic_int_n;

//------------------------------------------------------------------
// ROM banking — validated against MAME offroad_bankswitch()
//
// bank_reg [2:0] selects one of 8 entries in the bank_list table.
// Each entry is the byte offset into the flat 256 KB master ROM
// where the 48 KB banked window (Z80 0x2000-0xDFFF) begins.
//
// rom_addr for banked access = bank_offset[bank_reg] + (cpu_addr - 0x2000)
// rom_addr for fixed  access = cpu_addr[12:0]  (8 KB at master_rom[0])
//------------------------------------------------------------------
reg [2:0] bank_reg;

// bank_list from MAME offroad_bankswitch (offsets into master_rom region)
reg [17:0] bank_offset;
always @(*) begin
	case (bank_reg)
		3'd0: bank_offset = 18'h02000;
		3'd1: bank_offset = 18'h02000;
		3'd2: bank_offset = 18'h10000;
		3'd3: bank_offset = 18'h18000;
		3'd4: bank_offset = 18'h20000;
		3'd5: bank_offset = 18'h28000;
		3'd6: bank_offset = 18'h30000;
		3'd7: bank_offset = 18'h38000;
	endcase
end

wire mem_access = ~mreq_n & rfsh_n;
wire in_fixed      = (cpu_addr[15:13] == 3'b000);       // 0x0000-0x1FFF
wire in_banked_lo  = (cpu_addr[15:13] >= 3'd1) &&
                     (cpu_addr[15:13] <= 3'd4);          // 0x2000-0x9FFF (truly bank-switched)
wire in_high       = (cpu_addr[15:13] == 3'b101) ||
                     (cpu_addr[15:13] == 3'b110);        // 0xA000-0xDFFF
wire in_battram    = in_high & (bank_reg == 3'd1);       // battery RAM view selected
wire in_fixed_high = in_high & ~in_battram;              // falls through to fixed ROM
wire in_wram       = (cpu_addr[15:12] == 4'hE);          // 0xE000-0xEFFF

// ROM read indicator used by leland_board to drive SDRAM stall logic --
// excludes in_battram, which is real RAM, not SDRAM-backed ROM.
assign rom_req = mem_access & ~rd_n & (in_fixed | in_banked_lo | in_fixed_high);
wire in_cram   = (cpu_addr[15:10] == 6'b111100);        // 0xF000-0xF3FF
wire in_vidlat = (cpu_addr[15:1]  == 15'h7C00);         // 0xF800-0xF801

// rom_addr. The fixed region uses cpu_addr directly. Fixed-high (0xA000-0xDFFF while
// the battery RAM view is off) is unbanked: master_redline_map_program maps it straight
// to region offset 0xA000.
//
// Banked-low (0x2000-0x9FFF), verified against MAME's live execution:
//   bank_reg 0/1 (bank_offset 0x2000): rom_addr == cpu_addr
//   bank_reg >= 2: rom_addr == bank_offset + cpu_addr[14:0]. It is not window-relative,
//     and A15 is ignored: $8000-$9FFF alias back onto $0000-$1FFF of the same bank, as
//     if only cpu_addr[14:0] reaches the banked chip.
// This formula already is the rotate_memory("master") compensation (cpu_addr[14:0] ==
// ((cpu_addr - 0x2000) + 0x2000) mod 0x8000). Adding another +0x2000 double-rotates by
// the slave's amount and breaks master execution, so do not change it without
// re-deriving.
assign rom_addr = in_fixed      ? {5'b0, cpu_addr[12:0]} :
                  in_fixed_high ? {2'b0, cpu_addr} :
                  (bank_offset == 18'h02000) ? {2'b0, cpu_addr} :
                                                bank_offset + {3'b0, cpu_addr[14:0]};

//------------------------------------------------------------------
// Battery-backed RAM (0xA000-0xDFFF, selected when bank_reg==1)
//------------------------------------------------------------------
assign battram_addr = cpu_addr - 16'hA000;
assign battram_din  = cpu_dout;
assign battram_we   = mem_access & ~wr_n & in_battram;

//------------------------------------------------------------------
// Work RAM
//------------------------------------------------------------------
assign wram_addr = cpu_addr[11:0];
assign wram_din  = cpu_dout;
assign wram_we   = mem_access & ~wr_n & in_wram;

//------------------------------------------------------------------
// Color RAM
//------------------------------------------------------------------
assign cram_addr = cpu_addr[9:0];
assign cram_din  = cpu_dout;
// cram_we is assigned further down, gated on mcont_r[1].

//------------------------------------------------------------------
// Video address latch (0xF800-0xF801)
//------------------------------------------------------------------
reg [15:0] vid_addr_r;
reg        vid_addr_wr_r;

always @(posedge clk_sys) begin
	vid_addr_wr_r <= 0;
	if (CE_6M && mem_access && ~wr_n && in_vidlat) begin
		if (!cpu_addr[0]) vid_addr_r[7:0]  <= cpu_dout;
		else              vid_addr_r[15:8] <= cpu_dout;
		vid_addr_wr_r <= 1;
	end
end

assign vid_addr    = vid_addr_r;
assign vid_addr_wr = vid_addr_wr_r;

//------------------------------------------------------------------
// I/O decode
//------------------------------------------------------------------
wire io_rd = ~iorq_n & ~rd_n;
wire io_wr = ~iorq_n & ~wr_n;

// leland_mvram_port_r/w range, parameterised by mvram_base (MAME init_master_ports).
// Off-Road installs it twice (mvram_base 0x00 and 0x40, dual_io_window); Track-Pak and
// Pig Out install it once. Declared here so ModelSim does not infer an implicit net at
// first use.
wire [7:0] mvram_base_alt = mvram_base ^ 8'h40;
wire io_mvram = (cpu_addr[7:5] == mvram_base[7:5]) ||
                (dual_io_window && (cpu_addr[7:5] == mvram_base_alt[7:5]));

//------------------------------------------------------------------
// VRAM I/O port (leland_mvram_port_r/w). TRANS_EN=0: the Master is
// num=0 in MAME's vram_port_w, so its bit-4 transparency bit is
// ignored (transparency is Slave-only).
//------------------------------------------------------------------
wire [7:0] vram_rd_data;

leland_vram_port #(.TRANS_EN(1'b0)) mvport
(
	.clk_sys(clk_sys),
	.reset(reset),
	.CE_6M(CE_6M),

	.cpu_addr(cpu_addr),
	.cpu_dout(cpu_dout),
	.io_wr(io_wr),
	.io_rd(io_rd),
	.io_vram_sel(io_mvram),
	.vidlat_wr(CE_6M && mem_access && ~wr_n && in_vidlat),
	.vidlat_hi(cpu_addr[0]),

	.rd_data(vram_rd_data),
	.vp_stall(mvport_stall),

	.vp_req(vp_req),
	.vp_rd(vp_rd),
	.vp_trans(vp_trans),
	.vp_addr(vp_addr),
	.vp_data(vp_data),
	.vp_pop(vp_pop),
	.vp_rdata(vp_rdata)
);

// MAME redline_state::init_offroad installs the shared leland_master_input_r/output_w
// handlers (GIN, mcont, ay, scroll) at io_base+offset, aliased at both io_base=0xC0 and
// 0x80, so the physical /MCONT port is 0xC9 (mirrored at 0x89), not the raw offset 0x09.
// bank/cmd/stat/pal are static entries (0xF0/0xF2/0xF3/0xF4) and are not relocated.
wire io_bank  = (cpu_addr[7:0] == 8'hF0);   // bank register write (static map entry)
wire io_adc1  = (cpu_addr[7:0] == 8'hFD);   // P1 pedal, raw (MAME port 0xFD)
wire io_adc2  = (cpu_addr[7:0] == 8'hFE);   // P2 pedal, raw
wire io_adc3  = (cpu_addr[7:0] == 8'hFF);   // P3 pedal, raw
// Wheel ports (MAME init_offroad/init_offroadt): fixed dial-encoded reads at 0xF9 (P1),
// 0xFB (P2) and 0xF8 (P3), separate from the pedal ports; unused by Pig Out.
wire io_wheel1 = (cpu_addr[7:0] == 8'hF9);  // P1 wheel (offroad_wheel_1_r)
wire io_wheel2 = (cpu_addr[7:0] == 8'hFB);  // P2 wheel (offroad_wheel_2_r)
wire io_wheel3 = (cpu_addr[7:0] == 8'hF8);  // P3 wheel (offroad_wheel_3_r)

// The relocated leland_master_input_r/output_w window (GIN0/1/3, mcont, ay, scroll) is
// parameterised by io_base (MAME init_master_ports(mvram_base, io_base)); dual_io_window
// reproduces Off-Road's double install (base and base^0x40). Offsets inside the window
// are fixed by MAME: 0x00/0x01 GIN0/1, 0x09 mcont, 0x0A/0x0B ay, 0x0C-0x0F scroll,
// 0x11 GIN3.
wire [7:0] io_base_alt = io_base ^ 8'h40;
function automatic io_win(input [7:0] offset);
	io_win = (cpu_addr[7:0] == (io_base + offset)) ||
	         (dual_io_window && (cpu_addr[7:0] == (io_base_alt + offset)));
endfunction

wire io_mcont = io_win(8'h09);
// AY-3-8910 register select (/OGIA, offset 0x0A) and data (/OGID, offset 0x0B) writes;
// see gfxbank above.
wire io_ay_addr = io_win(8'h0A);
wire io_ay_data = io_win(8'h0B);
// MAME master_redline_map_io: 0xF2 = 80186 response_r / command_lo_w, 0xF4 =
// command_hi_w (write-only). Neither is a palette register; Off-Road has no palette-bank
// register, only the /MCONT bit 1 palette view.
wire io_cmd   = (cpu_addr[7:0] == 8'hF2);   // sound command_lo_w / response_r
wire io_snd_hi = (cpu_addr[7:0] == 8'hF4);  // sound command_hi_w (write-only)

// Background scroll registers (MAME scroll_w, offset 0x0C-0x0F relative
// to io_base -- see leland.cpp init_offroad()/init_offroadt()/init_pigout()).
wire io_scroll_xlo = io_win(8'h0C);
wire io_scroll_xhi = io_win(8'h0D);
wire io_scroll_ylo = io_win(8'h0E);
wire io_scroll_yhi = io_win(8'h0F);

// Wheel dial encoder (MAME leland_m.cpp dial_compute_value): each read reports the
// direction (bit 7) and magnitude (bits 4:0, clamped to 0x1F, accumulated mod 32) of
// wheel motion since the last read of the same port, never an absolute angle.
// wheelN_now is combinational from the live p*_wheel so the value returned on this read
// already includes the motion; wheelN_last_input/wheelN_result latch once per read.
// Latching on every CE_6M tick of a single IN is safe: the wheel has not moved, so a
// repeat tick computes a delta of 0.
function automatic [7:0] dial_compute(input [7:0] new_val, input [7:0] last_val, input [7:0] last_result);
	reg signed [8:0] delta;
	reg        [7:0] result;
	begin
		delta  = $signed({1'b0, new_val}) - $signed({1'b0, last_val});
		result = last_result & 8'h80;
		if (delta > 9'sd128)       delta = delta - 9'sd256;
		else if (delta < -9'sd128) delta = delta + 9'sd256;
		if (delta < 0) begin
			result = 8'h80;
			delta  = -delta;
		end else if (delta > 0) begin
			result = 8'h00;
		end
		if (delta > 9'sd31) delta = 9'sd31;
		result = result | ((last_result + delta[7:0]) & 8'h1F);
		dial_compute = result;
	end
endfunction

reg [7:0] wheel1_last_input, wheel2_last_input, wheel3_last_input;
reg [7:0] wheel1_result,     wheel2_result,     wheel3_result;

wire [7:0] wheel1_now = dial_compute(p1_wheel, wheel1_last_input, wheel1_result);
wire [7:0] wheel2_now = dial_compute(p2_wheel, wheel2_last_input, wheel2_result);
wire [7:0] wheel3_now = dial_compute(p3_wheel, wheel3_last_input, wheel3_result);

always @(posedge clk_sys) begin
	if (reset) begin
		wheel1_last_input <= 8'h00; wheel1_result <= 8'h00;
		wheel2_last_input <= 8'h00; wheel2_result <= 8'h00;
		wheel3_last_input <= 8'h00; wheel3_result <= 8'h00;
	end else if (CE_6M && io_rd) begin
		if (io_wheel1) begin wheel1_result <= wheel1_now; wheel1_last_input <= p1_wheel; end
		if (io_wheel2) begin wheel2_result <= wheel2_now; wheel2_last_input <= p2_wheel; end
		if (io_wheel3) begin wheel3_result <= wheel3_now; wheel3_last_input <= p3_wheel; end
	end
end

// GIN input ports — validated against MAME INPUT_PORTS and
// leland_master_input_r (leland_m.cpp), parameterized by io_base (see
// io_win() above). GIN0/1 sit at io_base+0/+1, GIN3 at io_base+0x11.
wire io_gin0  = io_win(8'h00);
wire io_gin1  = io_win(8'h01);
wire io_gin3  = io_win(8'h11);

// WHEELS3_PEDALS3 (offroad/offroadt) GIN0: nitro buttons, active-low
// (0=pressed). bit4=P1BTN1, bit5=P2BTN1, bit6=P3BTN1; other bits float high.
wire [7:0] gin0_wheels = {1'b1,
                          ~p3_btn[1],  // bit6: P3 nitro
                          ~p2_btn[1],  // bit5: P2 nitro
                          ~p1_btn[1],  // bit4: P1 nitro
                          4'hF};

// WHEELS3_PEDALS3 GIN1: slave HALT (bit0 active-low), coin inputs
// (bits1-3 active-low). bit1=COIN3, bit2=COIN2, bit3=COIN1 (MAME offroad
// INPUT_PORTS IN1 order is NOT P1/P2/P3).
wire [7:0] gin1_wheels = {4'hF,
                          ~p1_btn[3],  // bit3: coin P1
                          ~p2_btn[3],  // bit2: coin P2
                          ~p3_btn[3],  // bit1: coin P3
                          slave_halt_n}; // bit0: SLAVEHALT

// JOY4_DIGITAL (pigout) GIN0 (leland.cpp INPUT_PORTS_START(pigout), IN0 @
// io_base+0): bit1=P3BTN2, bit2=P3right, bit3=P3down, bit5=P2BTN2,
// bit6=P2left, bit7=P2up. p*_joy bit layout: [0]=right [1]=left [2]=down
// [3]=up [4]=btn1 [5]=btn2 [6]=start [7]=coin.
// All bits below are active-low on the real bus (0=pressed); p*_joy from
// MiSTer is active-high (1=pressed), hence the ~ on every mapped bit.
wire [7:0] gin0_joy4 = {~p2_joy[3],  // bit7: P2 up
                        ~p2_joy[1],  // bit6: P2 left
                        ~p2_joy[5],  // bit5: P2 btn2
                        1'b1,        // bit4: unused
                        ~p3_joy[2],  // bit3: P3 down
                        ~p3_joy[0],  // bit2: P3 right
                        ~p3_joy[5],  // bit1: P3 btn2
                        1'b1};       // bit0: unused

// JOY4_DIGITAL GIN1 (pigout IN1 @ io_base+1): bit0=SLAVEHALT, bit1=COIN1,
// bit3=COIN2 (bit2 read but never referenced by the real game).
wire [7:0] gin1_joy4 = {4'hF,
                        ~p2_joy[7],  // bit3: coin P2
                        1'b1,        // bit2: unreferenced
                        ~p1_joy[7],  // bit1: coin P1
                        slave_halt_n}; // bit0: SLAVEHALT

wire [7:0] gin0_data = (input_scheme == JOY4_DIGITAL) ? gin0_joy4 : gin0_wheels;
wire [7:0] gin1_data = (input_scheme == JOY4_DIGITAL) ? gin1_joy4 : gin1_wheels;

// GIN2 (io_base+0x10, JOY4_DIGITAL only -- pigout IN2): bit0=START3,
// bit1=P3BTN1, bit2=P3left, bit3=P3up, bit4=START2, bit5=P2BTN1,
// bit6=P2right, bit7=P2down. Unused for WHEELS3_PEDALS3 (never read).
wire io_gin2 = io_win(8'h10);
wire [7:0] gin2_data = {~p2_joy[2],  // bit7: P2 down
                        ~p2_joy[0],  // bit6: P2 right
                        ~p2_joy[4],  // bit5: P2 btn1
                        ~p2_joy[6],  // bit4: start2
                        ~p3_joy[3],  // bit3: P3 up
                        ~p3_joy[1],  // bit2: P3 left
                        ~p3_joy[4],  // bit1: P3 btn1
                        ~p3_joy[6]}; // bit0: start3

// GIN3 (io_base+0x11): EEPROM DO (bit 0), VBlank (bit 1), service (bit 2 for Pig Out,
// bit 3 for Off-Road/Track-Pak; the two INPUT_PORTS blocks differ).
wire [7:0] gin3_wheels = {4'hF,
                          ~service,    // bit3: service (active-low)
                          1'b1,        // bit2: unused, float high
                          ~vblank,     // bit1: VBlank (active-low)
                          eeprom_do};  // bit0: real 93C46 DO
wire [7:0] gin3_joy4 = {5'h1F,       // bits7:3: unused, float high
                        ~service,    // bit2: service (active-low)
                        ~vblank,     // bit1: VBlank (active-low)
                        eeprom_do};  // bit0: real 93C46 DO
wire [7:0] gin3_data = (input_scheme == JOY4_DIGITAL) ? gin3_joy4 : gin3_wheels;

// Pig Out: fixed IN4 at raw 0x7F (MAME init_pigout install_read_port, outside the
// io_base window): P1 joystick, two buttons and start.
wire io_gin4 = in4_port_en && (cpu_addr[7:0] == 8'h7F);
wire [7:0] gin4_data = {~p1_joy[6],  // bit7: start1
                        ~p1_joy[5],  // bit6: P1 btn2
                        ~p1_joy[4],  // bit5: P1 btn1
                        ~p1_joy[0],  // bit4: P1 right
                        ~p1_joy[1],  // bit3: P1 left
                        ~p1_joy[2],  // bit2: P1 down
                        ~p1_joy[3],  // bit1: P1 up
                        1'b1};       // bit0: unused

// I/O writes
// The sound command latch (leland_a.cpp command_lo_w/command_hi_w) lives in the sound
// board; ports 0xF2/0xF4 are forwarded to it through cmd_wr_data/cmd_wr_lo/cmd_wr_hi.
reg  [7:0] mcont_r;       // /MCONT shadow register

reg [15:0] scroll_x_r, scroll_y_r;

// Minimal AY-3-8910 shadow: only register 0x0E (I/O port A) matters, because it drives
// gfxbank. ay_addr_r resets to a value other than 0x0E so a stray data write before the
// first address write cannot latch garbage.
reg [3:0] ay_addr_r;
reg [7:0] gfxbank_r;

// Sound-board control latch: a one-cycle strobe on every io_bank write (port 0xF0 is
// both the graphics bank register and the 80186 control register). MAME's diff==0
// early-out is a software optimisation, not bus behaviour, and control_wr is idempotent.
reg [7:0] sound_ctrl_data_r;
reg       sound_ctrl_wr_r;
assign sound_ctrl_data = sound_ctrl_data_r;
assign sound_ctrl_wr   = sound_ctrl_wr_r;

// Sound command latch outputs (registered strobes).
reg [7:0] cmd_wr_data_r;
reg       cmd_wr_lo_r, cmd_wr_hi_r;
assign cmd_wr_data = {cmd_wr_data_r, cmd_wr_data_r};
assign cmd_wr_lo   = cmd_wr_lo_r;
assign cmd_wr_hi   = cmd_wr_hi_r;

always @(posedge clk_sys) begin
	if (reset) begin
		mcont_r          <= 8'h00;  // slave_reset_n=0: hold Slave in reset
		bank_reg         <= 3'd0;
		scroll_x_r       <= 16'd0;
		scroll_y_r       <= 16'd0;
		ay_addr_r        <= 4'hF;
		gfxbank_r        <= 8'h00;  // matches MAME machine_reset()'s sound_port_w(0)
		sound_ctrl_data_r <= 8'h00;
		sound_ctrl_wr_r   <= 1'b0;
		cmd_wr_data_r     <= 8'h00;
		cmd_wr_lo_r       <= 1'b0;
		cmd_wr_hi_r       <= 1'b0;
	end else begin
		sound_ctrl_wr_r <= 1'b0;
		cmd_wr_lo_r     <= 1'b0;
		cmd_wr_hi_r     <= 1'b0;
		if (CE_6M && io_wr) begin
			if (io_bank) begin
				bank_reg          <= cpu_dout[2:0];
				sound_ctrl_data_r <= cpu_dout;
				sound_ctrl_wr_r   <= 1'b1;
			end
			if (io_cmd) begin
				cmd_wr_data_r    <= cpu_dout;
				cmd_wr_lo_r      <= 1'b1;
			end
			if (io_snd_hi) begin
				cmd_wr_data_r  <= cpu_dout;
				cmd_wr_hi_r    <= 1'b1;
			end
			if (io_mcont) begin
				mcont_r         <= cpu_dout;
			end
			if (io_scroll_xlo) scroll_x_r[7:0]  <= cpu_dout;
			if (io_scroll_xhi) scroll_x_r[15:8] <= cpu_dout;
			if (io_scroll_ylo) scroll_y_r[7:0]  <= cpu_dout;
			if (io_scroll_yhi) scroll_y_r[15:8] <= cpu_dout;
			if (io_ay_addr) ay_addr_r <= cpu_dout[3:0];
			if (io_ay_data && (ay_addr_r == 4'hE)) gfxbank_r <= cpu_dout;
		end
	end
end

assign scroll_x      = scroll_x_r;
assign scroll_y      = scroll_y_r;
assign gfxbank        = gfxbank_r;
assign slave_reset_n = mcont_r[0];  // 1=run, 0=hold in reset
// MAME: set_input_line(NMI, BIT(data,2) ? CLEAR_LINE : ASSERT_LINE), so with the
// active-low slave_nmi_n the bit maps straight through. Inverting it fired a spurious
// NMI when the master released the slave from reset.
assign slave_nmi_n   = mcont_r[2]; // bit2=1 → clear NMI (active-low, no invert)
// /MCONT bit 3 is a held level (MAME: set_input_line(IRQ0, BIT(data,3) ? CLEAR : ASSERT)):
// the slave INT stays asserted until the master rewrites the bit, so a late EI on the
// slave still sees it.
assign slave_int_req = ~mcont_r[3];
// leland_master_output_w: m_eeprom->di_write(BIT(data,4)); clk_write(BIT(data,5)); cs_write(BIT(data,6));
assign eeprom_di  = mcont_r[4];
assign eeprom_clk = mcont_r[5];
assign eeprom_cs  = mcont_r[6];
// MAME leland_master_output_w: /MCONT bit 1 selects the palette view. While it is off
// the game's writes to 0xF000-0xF3FF are dropped; ungated, a stray write would corrupt
// palette entries the video indexes.
assign cram_we = mem_access & ~wr_n & in_cram & mcont_r[1];

//------------------------------------------------------------------
// CPU data input mux
//------------------------------------------------------------------
always @(*) begin
	cpu_din = 8'hFF;  // default: bus float
	if (mem_access && ~rd_n) begin
		if      (in_fixed || in_banked_lo || in_fixed_high) cpu_din = rom_data;
		else if (in_battram)             cpu_din = battram_dout;
		else if (in_wram)               cpu_din = wram_dout;
			// Palette RAM is readable while /MCONT bit 1 selects the palette view (MAME:
			// ram().w(palette write8)). The test path fills the palette with an LDIR that reads
			// it back (write a seed to F000, then LDIR F000->F001), so reads must return the
			// stored data. With the view off nothing is mapped there: 0xFF.
		else if (in_cram)               cpu_din = mcont_r[1] ? cram_dout : 8'hFF;
	end else if (io_rd) begin
		if      (io_gin0) cpu_din = gin0_data;
		else if (io_gin1) cpu_din = gin1_data;
		else if (io_gin2) cpu_din = gin2_data;
		else if (io_gin3) cpu_din = gin3_data;
		else if (io_gin4) cpu_din = gin4_data;
		else if (io_adc1) cpu_din = p1_pedal;
		else if (io_adc2) cpu_din = p2_pedal;
		else if (io_adc3) cpu_din = p3_pedal;
		else if (io_wheel1) cpu_din = wheel1_now;
		else if (io_wheel2) cpu_din = wheel2_now;
		else if (io_wheel3) cpu_din = wheel3_now;
			// Port 0xF2 read: the 80186 response latch (a separate register from the command
			// latch that is written at the same address).
		else if (io_cmd)  cpu_din = response_data;
		else if (io_mvram) cpu_din = vram_rd_data;
	end
end

endmodule
