// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// Ataxx master Z80 (MAME leland.cpp master_map_program_2 / master_map_io_2).

module leland_master_ataxx #(
	parameter bit ALLOW_BUS_HOLD = 0,
	parameter integer Z80_RECOVERY_PROFILE = 0
)
(
	input         clk_sys,
	input         reset,
	input         CE_6M,
	input         bus_hold,
	output        bus_held,

	output [19:0] rom_addr,
	input   [7:0] rom_data,
	output        rom_req,
	input         rom_stall,

	output [12:0] wram_addr,
	output  [7:0] wram_din,
	output        wram_we,
	input   [7:0] wram_dout,

	output [13:0] battram_addr,
	output  [7:0] battram_din,
	output        battram_we,
	input   [7:0] battram_dout,

	output [15:0] qram_addr,
	output  [7:0] qram_din,
	output        qram_we,
	input   [7:0] qram_dout,

	output [10:0] pal_addr,
	output  [7:0] pal_din,
	output        pal_we,
	input   [7:0] pal_dout,

	output        vp_req,
	output        vp_rd,
	output        vp_trans,
	output [15:0] vp_addr,
	output  [7:0] vp_data,
	input         vp_pop,
	input   [7:0] vp_rdata,

	output        slave_reset_n,
	output        slave_nmi_n,
	output        slave_int_req,
	input         slave_halt_n,

	input         vblank,
	input   [7:0] raster_line,

	output        eeprom_di,
	output        eeprom_clk,
	output        eeprom_cs,
	input         eeprom_do,

	output [15:0] vid_addr,
	output        vid_addr_wr,
	output [15:0] scroll_x,
	output [15:0] scroll_y,
	output  [7:0] master_bank_o,

	output  [7:0] sound_ctrl_data,
	output        sound_ctrl_wr,
	output [15:0] cmd_wr_data,
	output        cmd_wr_lo,
	output        cmd_wr_hi,
	input   [7:0] response_data,

	// Trackball accumulators (free-running mod 256) and digital inputs
	input   [7:0] p1_x, p1_y, p2_x, p2_y,
	input   [7:0] p1_joy, p2_joy,   // [4]=button [6]=start [7]=coin
	input         service,

	// WSF family (Indy Heat, Brute Force): banks 1-15, XROM, analog pedals, three players
	input         wsf_mode,
	input         joy3_mode,        // three digital joysticks on ports 0x0D-0x0F (Brute Force)
	input   [7:0] p3_joy,           // [4]=button [5]=button 2 [7]=coin
	input   [7:0] p1_pedal, p2_pedal, p3_pedal
);

wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;

assign bus_held = ~busak_n;

wire int_n_final;
wire mvport_stall;
wire cpu_ce;
wire cpu_t2;
wire [11:0] recovery_pending;
wire recovery_fault;
wire rom_wait_t2 = cpu_t2 && rom_req && rom_stall;
wire recovery_real_wait = mvport_stall;
wire [63:0] irq_root_clock;
wire [64:0] irq_event_clock;
wire [130:0] cpu_inputs;
wire raw_irq_n;
wire filtered_irq_n;
wire nmi_cpu;
wire ack_level = ~iorq_n && ~m1_n;

tv80s_ce #(.Mode(0), .T2Write(1), .IOWait(1)) master_cpu
(
	.reset_n(~reset),
	.clk    (clk_sys),
	.cen    (cpu_ce),
	.read_t2(cpu_t2),
	.wait_n (~((rom_req & rom_stall) | mvport_stall)),
	.int_n  (int_n_final),
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

wire mem_access = ~mreq_n & rfsh_n;
wire io_rd = ~iorq_n & ~rd_n;
wire io_wr = ~iorq_n & ~wr_n;

reg [7:0] master_bank;
assign master_bank_o = master_bank;

wire [1:0] view     = master_bank[5:4];
wire       bat_view = (view == 2'd1);
wire       qram_view = (view == 2'd2);
wire       pal_view = (view == 2'd3);

// Interrupt: once per frame at a programmable scanline, held until acknowledged.
reg [7:0] int_line;
reg [7:0] raster_prev;
reg       periodic_int_n;

always @(posedge clk_sys) raster_prev <= raster_line;

generate
	if (Z80_RECOVERY_PROFILE == 0) begin : g_z80_legacy
		assign cpu_ce = CE_6M;
		assign recovery_pending = 12'd0;
		assign recovery_fault = 1'b0;
		assign irq_root_clock = 64'd0;
		assign irq_event_clock = 65'd0;
		assign cpu_inputs = 131'd0;
		assign raw_irq_n = periodic_int_n;
		assign filtered_irq_n = periodic_int_n;
		assign nmi_cpu = 1'b1;
		assign int_n_final = periodic_int_n;
		always @(posedge clk_sys) begin
			if (reset)
				periodic_int_n <= 1'b1;
			else if ((raster_line != raster_prev) && (raster_line == int_line))
				periodic_int_n <= 1'b0;
			else if (CE_6M && ack_level)
				periodic_int_n <= 1'b1;
		end
	end else if (Z80_RECOVERY_PROFILE == 1) begin : g_z80_recovery
		leland_irq_source recovery_irq_source(
			.clk(clk_sys), .reset(reset),
			.set_irq((raster_line != raster_prev) && (raster_line == int_line)),
			.acknowledge(cpu_ce && ack_level), .ack_clock(cpu_inputs[130:67]),
			.irq_n(raw_irq_n), .root_clock(irq_root_clock), .event_clock(irq_event_clock));
		leland_cpu_input_recovery #(.INPUT_WIDTH(131), .CREDIT_WIDTH(12), .MIN_GAP(4)) recovery_clock(
			.clk(clk_sys), .reset(reset), .pause(1'b0), .nominal_ce(CE_6M),
			.artificial_wait(rom_wait_t2),
			.input_now({irq_root_clock, irq_event_clock, 1'b1, raw_irq_n}),
			.input_at_cpu(cpu_inputs), .cpu_ce(cpu_ce),
			.pending(recovery_pending), .fault(recovery_fault));
		leland_irq_input_filter recovery_irq_filter(
			.clk(clk_sys), .reset(reset), .cpu_ce(cpu_ce), .acknowledge(ack_level),
			.sampled_clock(cpu_inputs[130:67]), .event_clock(cpu_inputs[66:2]),
			.sampled_irq_n(cpu_inputs[0]), .irq_cpu_n(filtered_irq_n));
		assign nmi_cpu = 1'b1;
		assign int_n_final = filtered_irq_n;
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
		assign int_n_final = 1'b1;
		initial $fatal(1, "Unsupported Z80_RECOVERY_PROFILE=%0d", Z80_RECOVERY_PROFILE);
	end
endgenerate

// Memory decode
wire in_fixed    = (cpu_addr[15:13] == 3'd0);
wire in_banked   = (cpu_addr[15:13] >= 3'd1) && (cpu_addr[15:13] <= 3'd4);
wire in_high     = (cpu_addr[15:13] == 3'd5) || (cpu_addr[15:13] == 3'd6);
wire in_battram  = in_high & bat_view;
wire in_qram     = in_high & qram_view;
wire in_high_rom = in_high & ~bat_view & ~qram_view;
wire in_ram      = (cpu_addr >= 16'hE000) && (cpu_addr <= 16'hF7FF);
wire in_top      = (cpu_addr[15:11] == 5'b11111);
wire in_pal      = in_top & pal_view;
wire in_tram     = in_top & ~pal_view & (cpu_addr[10:2] != 9'h1FF);
wire in_vidlat   = in_top & ~pal_view & (cpu_addr[10:1] == 10'h3FC);
wire in_xrom     = in_top & ~pal_view & (cpu_addr[10:2] == 9'h1FF);

assign rom_req = mem_access & ~rd_n & (in_fixed | in_banked | in_high_rom | (wsf_mode & in_xrom));

// Bank n lands on the 32 KB block at 0x8000*n of the raw ROM (Ataxx has banks 1-3, the WSF
// family 1-15); bank 0 and out-of-range banks map the window straight onto the raw image.
wire bank_raw = (master_bank[3:0] == 4'd0) || (!wsf_mode && master_bank[3:2] != 2'd0);
wire [18:0] code_addr = (in_banked & ~bank_raw) ? {master_bank[3:0], cpu_addr[14:0]} : {3'b0, cpu_addr};

// XROM: two 16-bit address registers, the byte read back is chosen by cpu_addr[0].
reg [15:0] xrom_ptr [0:1];
wire [17:0] xrom_off = {cpu_addr[1], xrom_ptr[cpu_addr[1]], cpu_addr[0]};
assign rom_addr = (wsf_mode & in_xrom) ? {2'b10, xrom_off} : {1'b0, code_addr};

always @(posedge clk_sys) begin
	if (cpu_ce && mem_access && ~wr_n && in_xrom && wsf_mode) begin
		if (cpu_addr[0]) xrom_ptr[cpu_addr[1]][15:8] <= cpu_dout;
		else             xrom_ptr[cpu_addr[1]][7:0]  <= cpu_dout;
	end
end

// RAM
assign wram_addr = cpu_addr[12:0];
assign wram_din  = cpu_dout;
assign wram_we   = mem_access & ~wr_n & (in_ram | in_tram) & ~in_vidlat;

wire [15:0] hi_off = cpu_addr - 16'hA000;
assign battram_addr = hi_off[13:0];
assign battram_din  = cpu_dout;
assign battram_we   = mem_access & ~wr_n & in_battram;

assign qram_addr = {master_bank[7:6], hi_off[13:0]};
assign qram_din  = cpu_dout;
assign qram_we   = mem_access & ~wr_n & in_qram;

assign pal_addr = cpu_addr[10:0];
assign pal_din  = cpu_dout;
assign pal_we   = mem_access & ~wr_n & in_pal;

// Video address latch at 0xFFF8/0xFFF9
reg [15:0] vid_addr_r;
reg        vid_addr_wr_r;
always @(posedge clk_sys) begin
	vid_addr_wr_r <= 1'b0;
	if (cpu_ce && mem_access && ~wr_n && in_vidlat) begin
		if (!cpu_addr[0]) vid_addr_r[7:0]  <= cpu_dout;
		else              vid_addr_r[15:8] <= cpu_dout;
		vid_addr_wr_r <= 1'b1;
	end
end
assign vid_addr    = vid_addr_r;
assign vid_addr_wr = vid_addr_wr_r;

// VRAM port at 0xD0-0xEF, offset shuffled as in ataxx_mvram_port_r/w
wire       io_vram = (cpu_addr[7:4] == 4'hD) || (cpu_addr[7:4] == 4'hE);
wire [4:0] vp_off  = {~cpu_addr[4], cpu_addr[3:0]};
wire [4:0] vp_shuf = {vp_off[4], vp_off[0], vp_off[3:1]};
wire [7:0] vram_rd_data;

leland_vram_port #(.TRANS_EN(1'b0)) mvport
(
	.clk_sys(clk_sys),
	.reset(reset),
	.CE_6M(cpu_ce),

	.cpu_addr({cpu_addr[15:5], vp_shuf}),
	.cpu_dout(cpu_dout),
	.io_wr(io_wr),
	.io_rd(io_rd),
	.io_vram_sel(io_vram),
	.vidlat_wr(cpu_ce && mem_access && ~wr_n && in_vidlat),
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

// Trackball dials (ataxx_trackball_r -> dial_compute_value)
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

wire io_dial = (cpu_addr[7:2] == 6'd0);

// Indy Heat analog window 0x08-0x0F: writing the pedal number to 0x0B latches that pedal, 0x09 reads it
wire io_ih = (cpu_addr[7:3] == 5'b00001);
reg [7:0] pedal_result;
always @(posedge clk_sys) begin
	if (reset)
		pedal_result <= 8'h00;
	else if (cpu_ce && io_wr && wsf_mode && cpu_addr[7:0] == 8'h0B)
		pedal_result <= (cpu_dout == 8'd0) ? p1_pedal : (cpu_dout == 8'd1) ? p2_pedal : (cpu_dout == 8'd2) ? p3_pedal : 8'h00;
end
wire [1:0] dial_ch = cpu_addr[1:0];

reg [7:0] dial_last [0:3];
reg [7:0] dial_res  [0:3];
wire [7:0] dial_in  [0:3];
assign dial_in[0] = p1_x;
assign dial_in[1] = p1_y;
assign dial_in[2] = p2_x;
assign dial_in[3] = p2_y;
wire [7:0] dial_now = dial_compute(dial_in[dial_ch], dial_last[dial_ch], dial_res[dial_ch]);

integer i;
always @(posedge clk_sys) begin
	if (reset) begin
		for (i = 0; i < 4; i = i + 1) begin
			dial_last[i] <= 8'h00;
			dial_res[i]  <= 8'h00;
		end
	end else if (cpu_ce && io_rd && io_dial) begin
		dial_res[dial_ch]  <= dial_now;
		dial_last[dial_ch] <= dial_in[dial_ch];
	end
end

// Inputs
wire io_resp  = (cpu_addr[7:0] == 8'h04);
wire io_eep   = (cpu_addr[7:0] == 8'h20);
wire io_f0    = (cpu_addr[7:4] == 4'hF);
wire [3:0] f_off = cpu_addr[3:0];

wire [7:0] in0_ax = {~p2_joy[4], ~p2_joy[6], ~p1_joy[4], ~p1_joy[6],
	~service, 1'b1, ~p2_joy[7], ~p1_joy[7]};
wire [7:0] in0_ih = {~p1_joy[5], 3'b111, p3_joy[7], p2_joy[7], p1_joy[7], 1'b1};
wire [7:0] in0_bf = {~service, 3'b111, p3_joy[7], p1_joy[7], p2_joy[7], 1'b1};
wire [7:0] in0 = joy3_mode ? in0_bf : wsf_mode ? in0_ih : in0_ax;

// Brute Force player ports: right, left, down, up, buttons 1-2, start (bit 7 unused)
wire [7:0] bf_p1 = {1'b1, ~p1_joy[6:0]};
wire [7:0] bf_p2 = {1'b1, ~p2_joy[6:0]};
wire [7:0] bf_p3 = {1'b1, ~p3_joy[6:0]};
wire [7:0] in1 = {6'h3F, ~vblank, ~slave_halt_n};

// Writes
reg [7:0] slave_ctl_r;
reg [15:0] scroll_x_r, scroll_y_r;
reg [7:0] eeprom_r;
reg [7:0] sound_ctrl_data_r;
reg       sound_ctrl_wr_r;
reg [7:0] cmd_wr_data_r;
reg       cmd_wr_lo_r, cmd_wr_hi_r;

always @(posedge clk_sys) begin
	if (reset) begin
		master_bank       <= 8'h00;
		slave_ctl_r       <= 8'h00;
		scroll_x_r        <= 16'd0;
		scroll_y_r        <= 16'd0;
		eeprom_r          <= 8'h00;
		int_line          <= 8'd8;
		sound_ctrl_data_r <= 8'h00;
		sound_ctrl_wr_r   <= 1'b0;
		cmd_wr_data_r     <= 8'h00;
		cmd_wr_lo_r       <= 1'b0;
		cmd_wr_hi_r       <= 1'b0;
	end else begin
		sound_ctrl_wr_r <= 1'b0;
		cmd_wr_lo_r     <= 1'b0;
		cmd_wr_hi_r     <= 1'b0;
		if (cpu_ce && io_wr) begin
			if (cpu_addr[7:0] == 8'h05) begin cmd_wr_data_r <= cpu_dout; cmd_wr_hi_r <= 1'b1; end
			if (cpu_addr[7:0] == 8'h06) begin cmd_wr_data_r <= cpu_dout; cmd_wr_lo_r <= 1'b1; end
			if (cpu_addr[7:0] == 8'h0C) begin
				sound_ctrl_data_r <= {cpu_dout[0], cpu_dout[1], cpu_dout[2], cpu_dout[3], 4'h0};
				sound_ctrl_wr_r   <= 1'b1;
			end
			if (io_eep) eeprom_r <= cpu_dout;
			if (io_f0) begin
				case (f_off)
					4'h0: scroll_x_r[7:0]  <= cpu_dout;
					4'h1: scroll_x_r[15:8] <= cpu_dout;
					4'h2: scroll_y_r[7:0]  <= cpu_dout;
					4'h3: scroll_y_r[15:8] <= cpu_dout;
					4'h4: master_bank      <= cpu_dout;
					4'h5: slave_ctl_r      <= cpu_dout;
					4'h8: int_line         <= cpu_dout + 8'd1;
					default: ;
				endcase
			end
		end
	end
end

assign scroll_x        = scroll_x_r;
assign scroll_y        = scroll_y_r;
assign slave_reset_n   = slave_ctl_r[4];
assign slave_nmi_n     = slave_ctl_r[2];
assign slave_int_req   = ~slave_ctl_r[0];
assign eeprom_di       = eeprom_r[4];
assign eeprom_clk      = eeprom_r[5];
assign eeprom_cs       = eeprom_r[6];
assign sound_ctrl_data = sound_ctrl_data_r;
assign sound_ctrl_wr   = sound_ctrl_wr_r;
assign cmd_wr_data     = {cmd_wr_data_r, cmd_wr_data_r};
assign cmd_wr_lo       = cmd_wr_lo_r;
assign cmd_wr_hi       = cmd_wr_hi_r;

always @(*) begin
	cpu_din = 8'hFF;
	if (mem_access && ~rd_n) begin
		if      (in_fixed || in_banked || in_high_rom || (wsf_mode && in_xrom)) cpu_din = rom_data;
		else if (in_battram)             cpu_din = battram_dout;
		else if (in_qram)                cpu_din = qram_dout;
		else if (in_ram || in_tram)      cpu_din = wram_dout;
		else if (in_pal)                 cpu_din = pal_dout;
		// without wsf_mode the xrom is unpopulated and reads as erased flash
	end else if (io_rd) begin
		if      (io_dial)  cpu_din = dial_now;
		else if (io_resp)  cpu_din = response_data;
		else if (io_eep)   cpu_din = {7'h7F, eeprom_do};
		else if (io_vram)  cpu_din = vram_rd_data;
		else if (io_f0 && f_off == 4'h6) cpu_din = in0;
		else if (io_f0 && f_off == 4'h7) cpu_din = in1;
		else if (wsf_mode && io_ih) begin
			case (cpu_addr[3:0])
				4'h8, 4'hA: cpu_din = 8'h00;
				4'h9:       cpu_din = pedal_result;
				4'hD:       cpu_din = joy3_mode ? bf_p2 : {7'h7F, ~p1_joy[4]};
				4'hE:       cpu_din = joy3_mode ? bf_p1 : {7'h7F, ~p2_joy[4]};
				4'hF:       cpu_din = joy3_mode ? bf_p3 : {~service, 6'h3F, ~p3_joy[4]};
				default:    cpu_din = 8'hFF;
			endcase
		end
	end
end

endmodule
