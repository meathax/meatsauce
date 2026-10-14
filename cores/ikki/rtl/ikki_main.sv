//============================================================================
// Ikki main Z80 — MAME ikki_state::main_map
//============================================================================
module ikki_main
(
	input         clk,
	input         reset,
	input         ce_cpu,
	input         pause,

	input         irq_n,
	input         irq_source,   // 0 = vblank (scanline 240), 1 = mid (120)
	output        m1_n,
	output        iorq_n,

	input   [7:0] rom_q,
	output [15:0] rom_addr,

	output [10:0] shared_addr,
	output  [7:0] shared_din,
	input   [7:0] shared_dout,
	output        shared_we,
	output        shared_req,

	output [10:0] vram_addr,
	output  [7:0] vram_din,
	input   [7:0] vram_dout,
	output        vram_we,

	input   [7:0] dsw1,
	input   [7:0] dsw2,
	input   [7:0] system,
	input   [7:0] p1,
	input   [7:0] p2,

	output reg    flipscreen,
	output reg [7:0] scroll_y,
	output reg [7:0] scroll_x,
	output reg [1:0] coin_cnt
);

wire reset_n = ~reset;
wire cpu_ena = ce_cpu & ~pause;

wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
wire  [7:0] cpu_din;
wire        mreq_n, rd_n, wr_n, rfsh_n;
wire        m1_n_w, iorq_n_w;

assign m1_n   = m1_n_w;
assign iorq_n = iorq_n_w;

T80se #(.Mode(0), .T2Write(1), .IOWait(0)) cpu
(
	.RESET_n(reset_n),
	.CLK_n(clk),
	.CLKEN(cpu_ena),
	.WAIT_n(1'b1),
	.INT_n(irq_n),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(m1_n_w),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n_w),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(rfsh_n),
	.HALT_n(),
	.BUSAK_n(),
	.A(cpu_addr),
	.DI(cpu_din),
	.DO(cpu_dout)
);

wire cpu_rd = ~mreq_n & ~rd_n & rfsh_n;
wire cpu_wr = ~mreq_n & ~wr_n & cpu_ena;

assign rom_addr = cpu_addr;

// Work RAM C000-C7FF
(* ramstyle = "M10K" *) reg [7:0] work_ram [0:2047];
reg [7:0] work_q;
wire work_cs = (cpu_addr[15:11] == 5'b11000); // C000-C7FF

always @(posedge clk) begin
	if (cpu_wr & work_cs)
		work_ram[cpu_addr[10:0]] <= cpu_dout;
	work_q <= work_ram[cpu_addr[10:0]];
end

// Shared C800-CFFF
wire shared_cs = (cpu_addr[15:11] == 5'b11001);
assign shared_addr = cpu_addr[10:0];
assign shared_din  = cpu_dout;
assign shared_we   = cpu_wr & shared_cs;
assign shared_req  = shared_cs & ~mreq_n & rfsh_n & (~rd_n | ~wr_n);

// VRAM D000-D7FF
wire vram_cs = (cpu_addr[15:11] == 5'b11010);
assign vram_addr = cpu_addr[10:0];
assign vram_din  = cpu_dout;
assign vram_we   = cpu_wr & vram_cs;

// I/O / control
wire io_cs = (cpu_addr[15:4] == 12'hE00);

always @(posedge clk) begin
	if (reset) begin
		flipscreen <= 1'b0;
		scroll_y   <= 8'd0;
		scroll_x   <= 8'd0;
		coin_cnt   <= 2'b00;
	end else if (cpu_wr & io_cs) begin
		case (cpu_addr[3:0])
			4'h8: flipscreen <= cpu_dout[2];
			4'h9: coin_cnt   <= cpu_dout[1:0];
			4'hA: scroll_y   <= cpu_dout;
			4'hB: scroll_x   <= cpu_dout;
			default: ;
		endcase
	end
end

reg [7:0] cpu_din_r;
always @(*) begin
	cpu_din_r = 8'hFF;
	if (cpu_addr < 16'hA000)
		cpu_din_r = rom_q;
	else if (work_cs)
		cpu_din_r = work_q;
	else if (shared_cs)
		cpu_din_r = shared_dout;
	else if (vram_cs)
		cpu_din_r = vram_dout;
	else if (io_cs) begin
		case (cpu_addr[3:0])
			4'h0: cpu_din_r = {6'b0, irq_source, 1'b0};
			4'h1: cpu_din_r = dsw1;
			4'h2: cpu_din_r = dsw2;
			4'h3: cpu_din_r = system;
			4'h4: cpu_din_r = p1;
			4'h5: cpu_din_r = p2;
			default: cpu_din_r = 8'hFF;
		endcase
	end
end
assign cpu_din = cpu_din_r;

wire _unused = cpu_rd;

endmodule
