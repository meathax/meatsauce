//============================================================================
// Universal Do! Castle family main Z80 and runtime-selectable memory map.
// MAME reference: src/mame/universal/docastle.cpp main_map variants.
//============================================================================
module docastle_main
(
	input         clk,
	input         reset,
	input         ce_cpu,
	input         pause,
	input   [1:0] profile,
	input         irq_n,

	input   [7:0] rom_q,
	output [15:0] rom_addr,

	input   [7:0] comm_latch,
	output  [7:0] comm_dout,
	output        comm_start,
	output        comm_write,
	input         comm_wait_n,

	output  [8:0] sprite_addr,
	output  [7:0] sprite_din,
	output        sprite_we,

	output  [9:0] video_addr,
	output  [7:0] video_din,
	input   [7:0] video_dout,
	output        video_we,

	output  [9:0] color_addr,
	output  [7:0] color_din,
	input   [7:0] color_dout,
	output        color_we,

	input   [7:0] adpcm_status,
	output        adpcm_wr,
	output  [7:0] adpcm_data,

	output reg [4:0] crtc_reg,
	output reg [7:0] crtc_data,
	output reg       crtc_we,
	output reg       sub_nmi_req,
	output           watchdog_kick,

	output [15:0] cpu_addr_debug,
	output        m1_n_debug,
	output        iorq_n_debug
);

localparam [1:0] PROFILE_CASTLE = 2'd0;
localparam [1:0] PROFILE_RUNRUN = 2'd1;
localparam [1:0] PROFILE_SOCCER = 2'd2;

wire is_runrun = profile == PROFILE_RUNRUN;
wire is_soccer = profile == PROFILE_SOCCER;
wire cpu_ena = ce_cpu & ~pause;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;

T80se #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
(
	.RESET_n(~reset), .CLK_n(clk), .CLKEN(cpu_ena),
	.WAIT_n(comm_wait_n), .INT_n(irq_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n),
	.WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(),
	.A(cpu_addr), .DI(cpu_din), .DO(cpu_dout)
);

assign cpu_addr_debug = cpu_addr;
assign m1_n_debug = m1_n;
assign iorq_n_debug = iorq_n;
assign rom_addr = cpu_addr;

wire mem_cycle = ~mreq_n & rfsh_n & (~rd_n | ~wr_n);
wire wr_level  = mem_cycle & ~wr_n;
wire rd_level  = mem_cycle & ~rd_n;
wire io_wr_level = ~iorq_n & ~wr_n;
reg wr_d, rd_d, io_wr_d;
wire wr_edge = wr_level & ~wr_d;
wire rd_edge = rd_level & ~rd_d;
wire io_wr_edge = io_wr_level & ~io_wr_d;

wire rom_cs = (profile == PROFILE_CASTLE)
	? (cpu_addr < 16'h8000)
	: is_runrun
		? ((cpu_addr < 16'h2000) || ((cpu_addr >= 16'h4000) && (cpu_addr <= 16'h9fff)))
		: ((cpu_addr < 16'h4000) || ((cpu_addr >= 16'h6000) && (cpu_addr <= 16'h9fff)));

wire ram_cs = (profile == PROFILE_CASTLE)
	? ((cpu_addr >= 16'h8000) && (cpu_addr <= 16'h97ff))
	: is_runrun
		? ((cpu_addr >= 16'h2000) && (cpu_addr <= 16'h37ff))
		: ((cpu_addr >= 16'h4000) && (cpu_addr <= 16'h57ff));

wire sprite_cs = (profile == PROFILE_CASTLE)
	? ((cpu_addr >= 16'h9800) && (cpu_addr <= 16'h99ff))
	: is_runrun
		? ((cpu_addr >= 16'h3800) && (cpu_addr <= 16'h39ff))
		: ((cpu_addr >= 16'h5800) && (cpu_addr <= 16'h59ff));

wire comm_cs = (cpu_addr >= 16'ha000) && (cpu_addr <= 16'ha7ff);
wire video_cs = is_runrun
	? ((cpu_addr >= 16'hb000) && (cpu_addr <= 16'hb3ff))
	: ((cpu_addr[15:12] == 4'hb) && !cpu_addr[10]);
wire color_cs = is_runrun
	? ((cpu_addr >= 16'hb400) && (cpu_addr <= 16'hb7ff))
	: ((cpu_addr[15:12] == 4'hb) && cpu_addr[10]);
wire adpcm_cs = is_soccer && (cpu_addr == 16'hc000);
wire nmi_cs = is_runrun ? (cpu_addr == 16'hb800) : (cpu_addr == 16'he000);
wire watchdog_cs = cpu_addr == 16'ha800;

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] work_ram [0:6143];
reg [7:0] work_q;
// All three 0x1800-byte RAM windows are aligned to 0x2000, so the low
// thirteen address bits are the physical RAM index.
wire [12:0] ram_addr = cpu_addr[12:0];
always @(posedge clk) begin
	work_q <= work_ram[ram_addr];
	if (wr_edge && ram_cs)
		work_ram[ram_addr] <= cpu_dout;
end

assign sprite_addr = cpu_addr[8:0];
assign sprite_din  = cpu_dout;
assign sprite_we   = wr_edge & sprite_cs;
assign video_addr  = cpu_addr[9:0];
assign video_din   = cpu_dout;
assign video_we    = wr_edge & video_cs;
assign color_addr  = cpu_addr[9:0];
assign color_din   = cpu_dout;
assign color_we    = wr_edge & color_cs;
assign comm_start  = (wr_edge | rd_edge) & comm_cs;
assign comm_write  = wr_edge & comm_cs;
assign comm_dout   = cpu_dout;
assign adpcm_wr    = wr_edge & adpcm_cs;
assign adpcm_data  = cpu_dout;
assign watchdog_kick = wr_edge & watchdog_cs;

always @(*) begin
	cpu_din = 8'hff;
	if (rom_cs)            cpu_din = rom_q;
	else if (ram_cs)       cpu_din = work_q;
	else if (comm_cs)      cpu_din = comm_latch;
	else if (video_cs)     cpu_din = video_dout;
	else if (color_cs)     cpu_din = color_dout;
	else if (adpcm_cs)     cpu_din = adpcm_status;
end

always @(posedge clk) begin
	if (reset) begin
		wr_d <= 0;
		rd_d <= 0;
		io_wr_d <= 0;
		crtc_reg <= 0;
		crtc_data <= 0;
		crtc_we <= 0;
		sub_nmi_req <= 0;
	end else begin
		wr_d <= wr_level;
		rd_d <= rd_level;
		io_wr_d <= io_wr_level;
		crtc_we <= 0;
		sub_nmi_req <= 0;

		if (wr_edge && nmi_cs)
			sub_nmi_req <= 1;

		if (io_wr_edge) begin
			case (cpu_addr[7:0])
			8'h00: crtc_reg <= cpu_dout[4:0];
			8'h02: begin
				crtc_data <= cpu_dout;
				crtc_we <= 1;
			end
			default: ;
			endcase
		end
	end
end

endmodule
