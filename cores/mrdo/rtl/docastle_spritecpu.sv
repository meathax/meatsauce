//============================================================================
// 8301 sprite/protection Z80 and the board's 0x200-byte sprite doorway.
//
// The main CPU writes an addressable staging latch at 0x9800/0x3800/0x5800.
// CPU3 reads that window at 0x8000, copies it through its 0x4321 work area,
// and then streams the protected bytes to the CF37201 doorway at 0xc000.
// copy_we observes the first transfer; cf_we is exclusively the real second
// transfer.  Keeping those phases separate is important to the board timing.
//============================================================================
module docastle_spritecpu
(
	input         clk,
	input         reset,
	input         ce_cpu,
	input         pause,
	input         pcb_fidelity,
	input         nmi_req,
	input         cf_irq_req,
	input   [8:0] main_addr,
	input   [7:0] main_data,
	input         main_we,
	input   [7:0] rom_q,
	output  [8:0] rom_addr,
	output reg [8:0] copy_addr,
	output reg [7:0] copy_data,
	output reg       copy_we,
	output reg [10:0] cf_addr,
	output reg  [7:0] cf_data,
	output reg        cf_we,
	output            cf_irq_ack,
	output [15:0] cpu_addr_debug
);

reg nmi_n;
reg int_n;
wire [15:0] cpu_addr;
wire [7:0] cpu_dout;
reg  [7:0] cpu_din;
wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
wire int_ack = ~m1_n & ~iorq_n;
assign cf_irq_ack = int_ack;

always @(posedge clk) begin
	if (reset) begin
		nmi_n <= 1;
		int_n <= 1;
	end else begin
		if (nmi_req) nmi_n <= 0;
		else if (ce_cpu) nmi_n <= 1;
		if (int_ack) int_n <= 1;
		if (pcb_fidelity && cf_irq_req) int_n <= 0;
		if (!pcb_fidelity) int_n <= 1;
	end
end

T80se #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
(
	.RESET_n(~reset), .CLK_n(clk), .CLKEN(ce_cpu & ~pause),
	.WAIT_n(1'b1), .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n),
	.RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(), .A(cpu_addr),
	.DI(cpu_din), .DO(cpu_dout)
);

assign rom_addr = cpu_addr[8:0];
assign cpu_addr_debug = cpu_addr;

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] staging_ram [0:511];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] work_ram [0:2047];
reg [7:0] staging_q, work_q;
wire stage_cs = (cpu_addr >= 16'h8000) && (cpu_addr <= 16'h81ff);
wire ram_cs = (cpu_addr >= 16'h4000) && (cpu_addr <= 16'h47ff);
wire cf_cs = (cpu_addr >= 16'hc000) && (cpu_addr <= 16'hc7ff);
wire mem_wr = ~mreq_n & ~wr_n & rfsh_n & ce_cpu;
wire ram_wr = mem_wr & ram_cs;
wire cf_wr = mem_wr & cf_cs;
wire copy_window = (cpu_addr >= 16'h4321) && (cpu_addr <= 16'h4520);

always @(posedge clk) begin
	staging_q <= staging_ram[cpu_addr[8:0]];
	work_q <= work_ram[cpu_addr[10:0]];
	if (main_we) staging_ram[main_addr] <= main_data;
	if (ram_wr) work_ram[cpu_addr[10:0]] <= cpu_dout;

	copy_we <= 0;
	cf_we <= 0;
	if (pcb_fidelity && ram_wr && copy_window) begin
		copy_addr <= cpu_addr[8:0] - 9'h121;
		copy_data <= cpu_dout;
		copy_we <= 1;
	end
	if (pcb_fidelity && cf_wr) begin
		cf_addr <= cpu_addr[10:0];
		cf_data <= cpu_dout;
		cf_we <= 1;
	end
	if (!pcb_fidelity) begin
		copy_we <= 0;
		cf_we <= 0;
	end
end

always @(*) begin
	cpu_din = 8'hff;
	if (cpu_addr <= 16'h00ff) cpu_din = rom_q;
	else if (ram_cs) cpu_din = work_q;
	else if (stage_cs) cpu_din = staging_q;
end

wire _unused = rd_n;
endmodule
