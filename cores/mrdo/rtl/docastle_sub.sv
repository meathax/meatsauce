//============================================================================
// Universal Do! Castle family sub/sound Z80, TMS1025 input mux, and 4x PSG.
//============================================================================
module docastle_sub
(
	input         clk,
	input         reset,
	input         ce_cpu,
	input         ce_psg,
	input         pause,
	input   [1:0] profile,
	input         irq_n,
	input         nmi_req,

	input   [7:0] rom_q,
	output [13:0] rom_addr,

	input   [7:0] comm_latch,
	output  [7:0] comm_dout,
	output        comm_access,
	output        comm_write,

	input   [7:0] dsw1,
	input   [7:0] dsw2,
	input   [7:0] joys,
	input   [7:0] joys2,
	input   [7:0] buttons,
	input   [7:0] system,
	output reg    flipscreen,

	output signed [15:0] audio,
	output [15:0] cpu_addr_debug,
	output        m1_n_debug,
	output        iorq_n_debug,
	output  [3:0] psg_ready_debug
);

localparam [1:0] PROFILE_RUNRUN = 2'd1;
wire is_runrun = profile == PROFILE_RUNRUN;
wire cpu_ena = ce_cpu & ~pause;
wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
reg   [7:0] cpu_din;
wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
wire [3:0] psg_ready;
wire cpu_wait_n = &psg_ready;
reg nmi_n;

always @(posedge clk) begin
	if (reset) nmi_n <= 1;
	else begin
		if (nmi_req) nmi_n <= 0;
		else if (ce_cpu) nmi_n <= 1;
	end
end

T80se #(.Mode(0), .T2Write(1), .IOWait(1)) cpu
(
	.RESET_n(~reset), .CLK_n(clk), .CLKEN(cpu_ena),
	.WAIT_n(cpu_wait_n), .INT_n(irq_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n),
	.WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(),
	.A(cpu_addr), .DI(cpu_din), .DO(cpu_dout)
);

assign cpu_addr_debug = cpu_addr;
assign m1_n_debug = m1_n;
assign iorq_n_debug = iorq_n;
assign psg_ready_debug = psg_ready;
assign rom_addr = cpu_addr[13:0];

wire mem_cycle = ~mreq_n & rfsh_n & (~rd_n | ~wr_n);
wire wr_level = mem_cycle & ~wr_n;
wire rd_level = mem_cycle & ~rd_n;
reg wr_d, rd_d;
wire wr_edge = wr_level & ~wr_d;
wire rd_edge = rd_level & ~rd_d;

wire ram_cs = (cpu_addr >= 16'h8000) && (cpu_addr <= 16'h87ff);
wire comm_cs = is_runrun
	? ((cpu_addr >= 16'he000) && (cpu_addr <= 16'he7ff))
	: ((cpu_addr >= 16'ha000) && (cpu_addr <= 16'ha7ff));
wire input_cs = (cpu_addr[15:8] == 8'hc0) && (cpu_addr[6:3] == 4'b0000);

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] work_ram [0:2047];
reg [7:0] work_q;

function automatic [7:0] input_mux(input [2:0] sel);
	begin
		case (sel)
			3'd1: input_mux = dsw2;
			3'd2: input_mux = dsw1;
			3'd3: input_mux = joys;
			3'd4: input_mux = joys2;
			3'd5: input_mux = buttons;
			3'd7: input_mux = system;
			default: input_mux = 8'hff;
		endcase
	end
endfunction

reg [2:0] input_sel;
reg [7:0] input_latch;
reg [7:0] input_hold;
wire [7:0] selected_input = input_mux(input_sel);

always @(posedge clk) begin
	work_q <= work_ram[cpu_addr[10:0]];
	if (wr_edge && ram_cs)
		work_ram[cpu_addr[10:0]] <= cpu_dout;

	if (reset) begin
		wr_d <= 0;
		rd_d <= 0;
		input_sel <= 0;
		input_latch <= 8'h00;
		input_hold <= 8'h00;
		flipscreen <= 0;
	end else begin
		wr_d <= wr_level;
		rd_d <= rd_level;

		// A read returns the previously selected TMS1025 port, then latches
		// A0-A2 for the next read. Port zero is high-Z and retains the value
		// last driven onto H. Reads and writes both latch A7 as flip-screen.
		if ((rd_edge || wr_edge) && input_cs)
			flipscreen <= cpu_addr[7];
		if (rd_edge && input_cs) begin
			input_latch <= (input_sel == 0) ? input_hold : selected_input;
			if (input_sel != 0) input_hold <= selected_input;
			input_sel <= cpu_addr[2:0];
		end
	end
end

assign comm_access = (rd_edge | wr_edge) & comm_cs;
assign comm_write  = wr_edge & comm_cs;
assign comm_dout   = cpu_dout;

always @(*) begin
	cpu_din = 8'hff;
	if (cpu_addr < 16'h4000) cpu_din = rom_q;
	else if (ram_cs)         cpu_din = work_q;
	else if (comm_cs)        cpu_din = comm_latch;
	else if (input_cs)       cpu_din = input_latch;
end

// One clean PSG strobe per Z80 write cycle. READY from any chip stalls the
// sub CPU, matching MAME's INPUT_MERGER_ANY_LOW wiring.
reg [3:0] sn_pulse;
reg [7:0] sn_data [0:3];
always @(posedge clk) begin
	if (reset) begin
		sn_pulse <= 0;
		sn_data[0] <= 0;
		sn_data[1] <= 0;
		sn_data[2] <= 0;
		sn_data[3] <= 0;
	end else begin
		sn_pulse <= 0;
		if (wr_edge) begin
			if (is_runrun) begin
				case (cpu_addr)
					16'ha000: begin sn_data[0] <= cpu_dout; sn_pulse[0] <= 1; end
					16'ha400: begin sn_data[1] <= cpu_dout; sn_pulse[1] <= 1; end
					16'ha800: begin sn_data[2] <= cpu_dout; sn_pulse[2] <= 1; end
					16'hac00: begin sn_data[3] <= cpu_dout; sn_pulse[3] <= 1; end
					default: ;
				endcase
			end else begin
				case (cpu_addr)
					16'he000: begin sn_data[0] <= cpu_dout; sn_pulse[0] <= 1; end
					16'he400: begin sn_data[1] <= cpu_dout; sn_pulse[1] <= 1; end
					16'he800: begin sn_data[2] <= cpu_dout; sn_pulse[2] <= 1; end
					16'hec00: begin sn_data[3] <= cpu_dout; sn_pulse[3] <= 1; end
					default: ;
				endcase
			end
		end
	end
end

wire signed [10:0] sn_sound [0:3];
genvar gi;
generate for (gi=0; gi<4; gi=gi+1) begin : psg
	jt89 #(.MODE(0)) chip
	(
		.rst(reset), .clk(clk), .clk_en(ce_psg),
		.wr_n(~sn_pulse[gi]), .cs_n(~sn_pulse[gi]), .din(sn_data[gi]),
		.sound(sn_sound[gi]), .ready(psg_ready[gi])
	);
end endgenerate

wire signed [12:0] sn0e = {{2{sn_sound[0][10]}},sn_sound[0]};
wire signed [12:0] sn1e = {{2{sn_sound[1][10]}},sn_sound[1]};
wire signed [12:0] sn2e = {{2{sn_sound[2][10]}},sn_sound[2]};
wire signed [12:0] sn3e = {{2{sn_sound[3][10]}},sn_sound[3]};
wire signed [13:0] sn_sum = sn0e + sn1e + sn2e + sn3e;
wire signed [17:0] scaled = $signed(sn_sum) * 18'sd8;
assign audio = (reset || pause) ? 16'sd0 : scaled[15:0];

endmodule
