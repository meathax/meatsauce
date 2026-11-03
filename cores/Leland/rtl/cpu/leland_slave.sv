// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  Leland - slave Z80
//
//  Memory map (MAME leland.cpp slave_large_map_program, used by the `lelandi` machine
//  config):
//    0x0000-0x1FFF  ROM bank 0 (fixed)
//    0x2000-0x3FFF  unmapped (reads 0xFF)
//    0x4000-0xBFFF  banked ROM window, 32 KB
//    0xC000         ROM bank register (write, bits [3:0])
//    0xC001-0xDFFF  unmapped (reads 0xFF)
//    0xE000-0xEFFF  work RAM (private to the slave)
//    0xF800/0xF801  VRAM address low/high (write; bit 7 of the high byte = addr[16])
//    0xF802         raster line counter (read)
//  I/O 0x00-0x1F (mirror 0x40): leland_svram_port_r/w, see leland_vram_port.sv
//  (op = addr[2:0], inc = addr[3], transparency = addr[4]).
//
//  Inter-CPU: there is no command port between the two Z80s. The master asserts the
//  slave INT line with /MCONT bit 3 and commands travel through a mailbox at the top of
//  shared video RAM (>= 0xF000), written and read through each CPU's VRAM I/O port. The
//  slave signals back by executing HALT, which the master polls on GIN1 bit 0.
//============================================================================

module leland_slave
(
	input         clk_sys,
	input         reset,
	input         CE_6M,

	// Slave program ROM
	output [18:0] rom_addr,
	input   [7:0] rom_data,

	// VRAM I/O port op stream (to leland_board's VRAM sequencer)
	output        vp_req,
	output        vp_rd,
	output        vp_trans,
	output [15:0] vp_addr,
	output  [7:0] vp_data,
	input         vp_pop,
	input   [7:0] vp_rdata,

	// Shared work RAM (same 4 KB as master)
	output [11:0] wram_addr,
	output  [7:0] wram_din,
	output        wram_we,
	input   [7:0] wram_dout,

	// Master asserted /MCONT bit3 → assert Slave INT (the only Slave INT
	// source in MAME; there is no Master->Slave command port)
	input         slave_int_req,

	// Master-driven NMI level (/MCONT bit 2), active low; tv80 detects the falling edge
	// itself.
	input         nmi_n,

	output        slave_halt_n,  // Z80 HALT output → Master GIN1 bit0 (SLAVEHALT)

	// Raster line counter from video circuit
	input   [7:0] raster_line,

	// SDRAM stall: high while a ROM byte is being fetched from SDRAM
	output        rom_req,    // level: high during any ROM read machine cycle
	input         rom_stall   // high = data not ready; insert Z80 wait states
);

//------------------------------------------------------------------
// Z80 bus
//------------------------------------------------------------------
wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;

//------------------------------------------------------------------
// Slave INT: /MCONT bit3 (leland_master_output_w case 0x09) is the
// only Slave INT source in MAME.
//------------------------------------------------------------------
reg int_n;
always @(posedge clk_sys) begin
	if (reset)
		int_n <= 1'b1;
	else if (slave_int_req)
		int_n <= 1'b0;
	else if (CE_6M && ~iorq_n && ~m1_n)  // INT acknowledge cycle
		int_n <= 1'b1;
end

// Memory region decode (declared before use by rom_read_cyc).
wire mem_access = ~mreq_n & rfsh_n;
wire in_fixed   = (cpu_addr[15:13] == 3'b000);            // 0x0000-0x1FFF
wire in_banked  = (cpu_addr >= 16'h4000) && (cpu_addr <= 16'hBFFF);

// ROM read: any access to fixed or banked ROM regions
wire rom_read_cyc = mem_access & ~rd_n & (in_fixed | in_banked);
assign rom_req = rom_read_cyc;

// vport_stall (from leland_vram_port below, forward-declared): holds the CPU in /WAIT
// instead of overwriting a VRAM port op that has not drained yet.
wire vport_stall;

// Insert wait states while SDRAM has not returned ROM data or the VRAM port cannot
// accept a new op.
wire cpu_wait_n = ~((rom_read_cyc & rom_stall) | vport_stall);

tv80s_ce #(.Mode(0), .T2Write(1), .IOWait(1)) slave_cpu
(
	.reset_n(~reset),
	.clk    (clk_sys),
	.cen    (CE_6M),
	.wait_n (cpu_wait_n),
	.int_n  (int_n),
	.nmi_n  (nmi_n),
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

assign slave_halt_n = halt_n;

//------------------------------------------------------------------
// ROM banking (MAME slave_large_map_program / slave_large_banksw_w): the bank register
// at 0xC000 (bits [3:0]) selects a 32 KB window at 0x4000-0xBFFF:
//   bankaddress = 0x10000 + 0x8000 * bank_reg, and bank_reg >= 14 falls back to 0x10000.
// Offsets are within the slave ROM region (leland_board adds ADDR_SLAVE_BASE):
//   0x00000 u3 (8 KB, fixed bank)      0x02000-0x2FFFF zero fill
//   0x30000 u4t  bank_reg 4/5          0x40000 u5t  bank_reg 6/7
//   0x50000 u6t  bank_reg 8/9          0x60000 u7t  bank_reg 10/11
//   0x70000 u8t  bank_reg 12/13
// bank_reg 0-3 land in the zero-fill gap, as in MAME.
//------------------------------------------------------------------
reg [3:0] bank_reg;

wire [18:0] bank_base = (bank_reg >= 4'd14) ? 19'h10000
                                             : (19'h10000 + {bank_reg, 15'd0});

//------------------------------------------------------------------
// Remaining memory region decode
//------------------------------------------------------------------
wire in_wram    = (cpu_addr[15:12] == 4'hE);              // 0xE000-0xEFFF
wire in_f8xx    = mem_access && (cpu_addr[15:8] == 8'hF8); // 0xF800-0xF8FF

// ROM address mux. MAME's init_offroad() calls rotate_memory("slave") twice, which
// left-rotates every 32 KB block from 0x10000 by 8 KB per call: a net rotation of half
// a block. For a 15-bit offset "+0x4000 mod 0x8000" is the same as inverting bit 14,
// so one XOR reproduces it (verified byte-exact against MAME's region dump). The
// zero-fill gap and the bank_reg>=14 fallback are covered too, since rotating zeros is
// a no-op.
assign rom_addr = in_fixed  ? {6'b0, cpu_addr[12:0]}
                            : bank_base + ((19'(cpu_addr) - 19'h4000) ^ 19'h4000);

//------------------------------------------------------------------
// Work RAM
//------------------------------------------------------------------
assign wram_addr = cpu_addr[11:0];
assign wram_din  = cpu_dout;
assign wram_we   = mem_access & ~wr_n & in_wram;

//------------------------------------------------------------------
// VRAM I/O port (leland_svram_port_r/w + slave_video_addr_w); the operation semantics
// live in leland_vram_port.sv. TRANS_EN=1 enables the slave's bit-4 transparency ops.
wire io_rd   = ~iorq_n & ~rd_n;
wire io_wr   = ~iorq_n & ~wr_n;
// MAME slave_map_io installs this handler at 0x00-0x1F with .mirror(0x40),
// i.e. bit 6 is a don't-care -- the same port also answers at 0x40-0x5F.
wire io_vram = (cpu_addr[7] == 1'b0) && (cpu_addr[5] == 1'b0); // I/O 0x00-0x1F, 0x40-0x5F

// Memory-mapped VRAM address latch: exactly 0xF800/0xF801
wire vidlat_wr = CE_6M && mem_access && ~wr_n && in_f8xx && (cpu_addr[7:1] == 7'd0);

wire [7:0] vram_rd_data;

leland_vram_port #(.TRANS_EN(1'b1)) vport
(
	.clk_sys(clk_sys),
	.reset(reset),
	.CE_6M(CE_6M),

	.cpu_addr(cpu_addr),
	.cpu_dout(cpu_dout),
	.io_wr(io_wr),
	.io_rd(io_rd),
	.io_vram_sel(io_vram),
	.vidlat_wr(vidlat_wr),
	.vidlat_hi(cpu_addr[0]),

	.rd_data(vram_rd_data),
	.vp_stall(vport_stall),

	.vp_req(vp_req),
	.vp_rd(vp_rd),
	.vp_trans(vp_trans),
	.vp_addr(vp_addr),
	.vp_data(vp_data),
	.vp_pop(vp_pop),
	.vp_rdata(vp_rdata)
);

//------------------------------------------------------------------
// Bank register write: exactly 0xC000 (MAME slave_large_banksw_w). The reset value 0
// matches MAME machine_reset().
wire bank_wr = CE_6M && mem_access && ~wr_n && (cpu_addr == 16'hC000);

always @(posedge clk_sys) begin
	if (reset)
		bank_reg <= 4'd0;
	else if (bank_wr)
		bank_reg <= cpu_dout[3:0]; // 0xC000 bank switch
end

//------------------------------------------------------------------
// CPU data input mux
//------------------------------------------------------------------
always @(*) begin
	cpu_din = 8'hFF;
	if (mem_access && ~rd_n) begin
		if      (in_fixed || in_banked) cpu_din = rom_data;
		else if (in_wram)               cpu_din = wram_dout;
		else if (in_f8xx && cpu_addr[1:0] == 2'b10) cpu_din = raster_line; // 0xF802
	end else if (io_rd) begin
		if (io_vram) cpu_din = vram_rd_data;
	end
end

endmodule
