// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// Ataxx slave Z80 (MAME leland.cpp ataxx_state::slave_map_program / slave_map_io_2).

module leland_slave_ataxx #(
	parameter bit ALLOW_BUS_HOLD = 0,
	parameter integer Z80_RECOVERY_PROFILE = 0
)
(
	input         clk_sys,
	input         reset,
	input         CE_6M,
	input         bus_hold,
	output        bus_held,
	input         wsf_mode,    // WSF family: 0x160000-byte ROM, banks up to 15 plus bit 5
	input         slave_1mb,   // WSF family with a 1 MB ROM: bank register bit 5 is unused
	input         asylum_mode,
	output reg    render_group_active,
	output reg    render_group_done,

	output [20:0] rom_addr,
	input   [7:0] rom_data,

	output        vp_req,
	output        vp_rd,
	output        vp_trans,
	output [15:0] vp_addr,
	output  [7:0] vp_data,
	input         vp_pop,
	input   [7:0] vp_rdata,

	output [12:0] wram_addr,
	output  [7:0] wram_din,
	output        wram_we,
	input   [7:0] wram_dout,

	input         slave_int_req,
	input         nmi_n,
	output        slave_halt_n,

	input   [7:0] raster_line,

	output        rom_req,
	input         rom_stall
);

wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;

assign bus_held = ~busak_n;

wire int_n;
reg legacy_int_n;
wire cpu_ce;
wire cpu_t2;
wire [11:0] recovery_pending;
wire recovery_fault;
wire vport_stall;
wire recovery_real_wait = vport_stall;
wire [63:0] irq_root_clock;
wire [64:0] irq_event_clock;
wire [130:0] cpu_inputs;
wire raw_irq_n;
wire filtered_irq_n;
wire nmi_cpu;
wire ack_level = ~iorq_n && ~m1_n;

wire mem_access = ~mreq_n & rfsh_n;
wire in_fixed   = (cpu_addr[15:13] == 3'd0);
wire in_banked  = (cpu_addr[15:13] >= 3'd1) && (cpu_addr[15:13] <= 3'd4);
wire in_rom_hi  = (cpu_addr[15:13] == 3'd5) || (cpu_addr[15:13] == 3'd6);
wire in_wram    = (cpu_addr[15:12] == 4'hE) ||
                  (asylum_mode && cpu_addr >= 16'hF000 && cpu_addr <= 16'hFFFB);
wire in_top     = (cpu_addr[15:2] == 14'h3FFF);

wire rom_read_cyc = mem_access & ~rd_n & (in_fixed | in_banked | in_rom_hi);
assign rom_req = rom_read_cyc;
wire rom_wait_t2 = cpu_t2 && rom_read_cyc && rom_stall;

wire cpu_wait_n = ~((rom_read_cyc & rom_stall) | vport_stall);

generate
	if (Z80_RECOVERY_PROFILE == 0) begin : g_z80_legacy
		assign cpu_ce = CE_6M;
		assign recovery_pending = 12'd0;
		assign recovery_fault = 1'b0;
		assign irq_root_clock = 64'd0;
		assign irq_event_clock = 65'd0;
		assign cpu_inputs = 131'd0;
		assign raw_irq_n = legacy_int_n;
		assign filtered_irq_n = legacy_int_n;
		assign nmi_cpu = nmi_n;
		assign int_n = legacy_int_n;
		always @(posedge clk_sys) begin
			if (reset)
				legacy_int_n <= 1'b1;
			else if (slave_int_req)
				legacy_int_n <= 1'b0;
			else if (CE_6M && ack_level)
				legacy_int_n <= 1'b1;
		end
	end else if (Z80_RECOVERY_PROFILE == 1) begin : g_z80_recovery
		leland_irq_source recovery_irq_source(
			.clk(clk_sys), .reset(reset), .set_irq(slave_int_req),
			.acknowledge(cpu_ce && ack_level), .ack_clock(cpu_inputs[130:67]),
			.irq_n(raw_irq_n), .root_clock(irq_root_clock), .event_clock(irq_event_clock));
		leland_cpu_input_recovery #(.INPUT_WIDTH(131), .CREDIT_WIDTH(12), .MIN_GAP(4)) recovery_clock(
			.clk(clk_sys), .reset(reset), .pause(1'b0), .nominal_ce(CE_6M),
			.artificial_wait(rom_wait_t2),
			.input_now({irq_root_clock, irq_event_clock, nmi_n, raw_irq_n}),
			.input_at_cpu(cpu_inputs), .cpu_ce(cpu_ce),
			.pending(recovery_pending), .fault(recovery_fault));
		leland_irq_input_filter recovery_irq_filter(
			.clk(clk_sys), .reset(reset), .cpu_ce(cpu_ce), .acknowledge(ack_level),
			.sampled_clock(cpu_inputs[130:67]), .event_clock(cpu_inputs[66:2]),
			.sampled_irq_n(cpu_inputs[0]), .irq_cpu_n(filtered_irq_n));
		assign nmi_cpu = cpu_inputs[1];
		assign int_n = filtered_irq_n;
	end else begin : g_z80_invalid_profile
		assign cpu_ce = 1'b0;
		assign recovery_pending = 12'hFFF;
		assign recovery_fault = 1'b1;
		assign irq_root_clock = 64'd0;
		assign irq_event_clock = 65'd0;
		assign cpu_inputs = 131'd0;
		assign raw_irq_n = 1'b1;
		assign filtered_irq_n = 1'b1;
		assign nmi_cpu = 1'b1;
		assign int_n = 1'b1;
		initial $fatal(1, "Unsupported Z80_RECOVERY_PROFILE=%0d", Z80_RECOVERY_PROFILE);
	end
endgenerate

tv80s_ce #(.Mode(0), .T2Write(1), .IOWait(1)) slave_cpu
(
	.reset_n(~reset),
	.clk    (clk_sys),
	.cen    (cpu_ce),
	.read_t2(cpu_t2),
	.wait_n (cpu_wait_n),
	.int_n  (int_n),
	.nmi_n  (nmi_cpu),
	.busrq_n(~(ALLOW_BUS_HOLD && bus_hold)),
	.m1_n   (m1_n),
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

// Fixed-ROM opcode fetches, never operand/data reads. These entry/exit
// points delimit the original erase-all/draw-all group in asy-sp0.151.
always @(posedge clk_sys) begin
 render_group_done <= 1'b0;
 if (reset || !asylum_mode) render_group_active <= 1'b0;
 else if (cpu_ce && !m1_n && !mreq_n && !rd_n) begin
  if (cpu_addr==16'h042A) render_group_active <= 1'b1;
  if (cpu_addr==16'h047E) begin
   render_group_active <= 1'b0;
   render_group_done <= render_group_active;
  end
 end
end
assign slave_halt_n = halt_n;

// Bank register (ataxx_slave_banksw_w): block at 0x10000*bank + 0x8000*data[4] (+0x100000*data[5]
// when the ROM is larger than 1 MB); bank 0 and blocks past the end of the ROM (0x60000 bytes
// for Ataxx, 0x160000 for the WSF family, 0x100000 with slave_1mb) map the window onto the raw
// image.
reg [5:0] bank_reg;
wire [3:0] bank = bank_reg[3:0];
wire [5:0] block = {bank_reg[5] & wsf_mode & ~slave_1mb, bank, bank_reg[4]};
wire bank_raw = (bank == 4'd0) || (block >= (asylum_mode ? 6'd60 : slave_1mb ? 6'd32 : wsf_mode ? 6'd44 : 6'd12));

assign rom_addr = (in_banked & ~bank_raw) ? {block, cpu_addr[14:0]}
	: {6'b0, cpu_addr};

assign wram_addr = cpu_addr[12:0];
assign wram_din  = cpu_dout;
assign wram_we   = mem_access & ~wr_n & in_wram;

// VRAM port at 0x60-0x7F, offset shuffled as in ataxx_svram_port_r/w
wire io_rd   = ~iorq_n & ~rd_n;
wire io_wr   = ~iorq_n & ~wr_n;
wire io_vram = (cpu_addr[7:5] == 3'b011);
wire [4:0] vp_shuf = {cpu_addr[4], cpu_addr[0], cpu_addr[3:1]};

wire vidlat_sel = in_top & ~cpu_addr[1];
wire vidlat_wr  = cpu_ce && mem_access && ~wr_n && vidlat_sel;

wire [7:0] vram_rd_data;

leland_vram_port #(.TRANS_EN(1'b1)) vport
(
	.clk_sys(clk_sys),
	.reset(reset),
	.CE_6M(cpu_ce),

	.cpu_addr({cpu_addr[15:5], vp_shuf}),
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

wire bank_wr = cpu_ce && mem_access && ~wr_n && (cpu_addr == 16'hFFFF);

always @(posedge clk_sys) begin
	if (reset)
		bank_reg <= 6'd1;
	else if (bank_wr)
		bank_reg <= cpu_dout[5:0];
end

always @(*) begin
	cpu_din = 8'hFF;
	if (mem_access && ~rd_n) begin
		if      (in_fixed || in_banked || in_rom_hi) cpu_din = rom_data;
		else if (in_wram)                            cpu_din = wram_dout;
		else if (in_top && cpu_addr[1:0] == 2'b10)   cpu_din = raster_line;
	end else if (io_rd) begin
		if (io_vram) cpu_din = vram_rd_data;
	end
end

endmodule
