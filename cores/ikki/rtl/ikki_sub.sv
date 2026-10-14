//============================================================================
// Ikki sub Z80 — sprite RAM, shared RAM, dual SN76489A (jt89)
//============================================================================
module ikki_sub
(
	input         clk,
	input         reset,
	input         ce_cpu,
	input         ce_sn1,   // ~2 MHz
	input         ce_sn2,   // ~4 MHz
	input         pause,
	input         wait_n,   // shared-RAM arbitration

	input         irq_n,
	output        m1_n,
	output        iorq_n,

	input   [7:0] rom_q,
	output [12:0] rom_addr,

	output [10:0] spr_addr,
	output  [7:0] spr_din,
	input   [7:0] spr_dout,
	output        spr_we,

	output [10:0] shared_addr,
	output  [7:0] shared_din,
	input   [7:0] shared_dout,
	output        shared_we,
	output        shared_req,

	output signed [15:0] audio
);

wire reset_n = ~reset;
wire cpu_ena = ce_cpu & ~pause;

wire [15:0] cpu_addr;
wire  [7:0] cpu_dout;
wire  [7:0] cpu_din;
wire        mreq_n, rd_n, wr_n, rfsh_n;
wire        m1_n_w, iorq_n_w;
wire        cpu_wait_n;

assign m1_n   = m1_n_w;
assign iorq_n = iorq_n_w;

T80se #(.Mode(0), .T2Write(1), .IOWait(0)) cpu
(
	.RESET_n(reset_n),
	.CLK_n(clk),
	.CLKEN(cpu_ena),
	.WAIT_n(cpu_wait_n),
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
wire cpu_wr = ~mreq_n & ~wr_n & cpu_ena & cpu_wait_n;

assign rom_addr = cpu_addr[12:0];

// Sprite RAM C000-C7FF
wire spr_cs = (cpu_addr[15:11] == 5'b11000);
assign spr_addr = cpu_addr[10:0];
assign spr_din  = cpu_dout;
assign spr_we   = cpu_wr & spr_cs;

// Shared C800-CFFF
wire shared_cs = (cpu_addr[15:11] == 5'b11001);
assign shared_addr = cpu_addr[10:0];
assign shared_din  = cpu_dout;
assign shared_we   = cpu_wr & shared_cs;
assign shared_req  = shared_cs & ~mreq_n & rfsh_n & (~rd_n | ~wr_n);

// ---- SN76489A ×2 via jt89 ----
// Hold each bus write until the PSG's own clock-enable edge.  The arcade
// hardware does not stall the sub Z80 on the SN76489 ready interval; the
// minimum Z80 instruction spacing is already longer than this pulse.
//
// The write strobe is the rising edge of the *bus* condition, sampled on the
// core clock and not gated by ce_cpu.  With T2Write the Z80 holds MREQ+WR
// across two T-states, so gating by ce_cpu produced two one-cycle pulses ten
// clocks apart.  SN1's hold state outlasts that gap, but SN2's clears after
// exactly ten clocks, so its second pulse could be latched as a duplicate
// write to the same register.
wire sn1_sel = ~mreq_n & ~wr_n & (cpu_addr == 16'hD801);
wire sn2_sel = ~mreq_n & ~wr_n & (cpu_addr == 16'hD802);

reg [7:0] sn1_data, sn2_data;
reg       sn1_wr_n, sn2_wr_n;
reg       sn1_cs_n, sn2_cs_n;
reg       sn1_sel_d, sn2_sel_d;
reg [1:0] sn1_st, sn2_st;
reg [15:0] sn1_wr_cnt, sn2_wr_cnt /* verilator public_flat_rw */;

localparam SN_IDLE  = 2'd0;
localparam SN_PULSE = 2'd1;

// One strobe per bus write, regardless of how many clock enables it spans.
wire sn1_wr = sn1_sel & ~sn1_sel_d;
wire sn2_wr = sn2_sel & ~sn2_sel_d;

always @(posedge clk) begin
	if (reset) begin
		sn1_data <= 8'h00;
		sn2_data <= 8'h00;
		sn1_wr_n <= 1'b1;
		sn2_wr_n <= 1'b1;
		sn1_cs_n <= 1'b1;
		sn2_cs_n <= 1'b1;
		sn1_sel_d <= 1'b0;
		sn2_sel_d <= 1'b0;
		sn1_st <= SN_IDLE;
		sn2_st <= SN_IDLE;
		sn1_wr_cnt <= 0;
		sn2_wr_cnt <= 0;
	end else begin
		sn1_sel_d <= sn1_sel;
		sn2_sel_d <= sn2_sel;

		// Terminate an in-flight pulse first, then let a fresh bus write
		// override, so no write can be dropped because the previous pulse had
		// not yet reached its clock enable.
		case (sn1_st)
		SN_IDLE: begin
			sn1_wr_n <= 1'b1;
			sn1_cs_n <= 1'b1;
		end
		SN_PULSE: begin
			if (ce_sn1) begin
				sn1_wr_n <= 1'b1;
				sn1_cs_n <= 1'b1;
				sn1_st <= SN_IDLE;
			end
		end
		default: sn1_st <= SN_IDLE;
		endcase

		if (sn1_wr) begin
			sn1_data   <= cpu_dout;
			sn1_cs_n   <= 1'b0;   // falling cs_n → jt89 ready low
			sn1_wr_n   <= 1'b0;
			sn1_wr_cnt <= sn1_wr_cnt + 1'd1;
			sn1_st     <= SN_PULSE;
		end

		case (sn2_st)
		SN_IDLE: begin
			sn2_wr_n <= 1'b1;
			sn2_cs_n <= 1'b1;
		end
		SN_PULSE: begin
			if (ce_sn2) begin
				sn2_wr_n <= 1'b1;
				sn2_cs_n <= 1'b1;
				sn2_st <= SN_IDLE;
			end
		end
		default: sn2_st <= SN_IDLE;
		endcase

		if (sn2_wr) begin
			sn2_data   <= cpu_dout;
			sn2_cs_n   <= 1'b0;
			sn2_wr_n   <= 1'b0;
			sn2_wr_cnt <= sn2_wr_cnt + 1'd1;
			sn2_st     <= SN_PULSE;
		end
	end
end

assign cpu_wait_n = wait_n;

wire signed [10:0] sn1_snd, sn2_snd /* verilator public_flat_rw */;

jt89 sn1
(
	.rst(reset),
	.clk(clk),
	.clk_en(ce_sn1),
	.wr_n(sn1_wr_n),
	.cs_n(sn1_cs_n),
	.din(sn1_data),
	.sound(sn1_snd),
	.ready()
);

jt89 sn2
(
	.rst(reset),
	.clk(clk),
	.clk_en(ce_sn2),
	.wr_n(sn2_wr_n),
	.cs_n(sn2_cs_n),
	.din(sn2_data),
	.sound(sn2_snd),
	.ready()
);

// MAME: each SN @ 0.75 into mono. jt89 is s11; mix and scale to s16.
wire signed [12:0] s1e = $signed({{2{sn1_snd[10]}}, sn1_snd});
wire signed [12:0] s2e = $signed({{2{sn2_snd[10]}}, sn2_snd});
wire signed [13:0] sum = $signed({s1e[12], s1e}) + $signed({s2e[12], s2e});
//
// Scale to MiSTer line level, chosen to match MAME's output level.
//
// Each jt89 output is s11, so `sum` spans +/-2046 and this peaks at +/-24552,
// three quarters of full scale -- headroom the game never approaches (its
// measured peak is about an eighth of that).
//
// Arrived at by measurement against a real MAME capture, in two steps:
//   factor  6  ->  rms 214 vs MAME 592, ratio 0.362   (2.8x quiet)
//   factor 16  ->  rms 808 vs MAME 592, ratio 1.367   (overshoot)
//   factor 12  ->  16 / 1.367 = 11.7, so 12
// The PSG command stream is byte-identical to MAME, so this was only ever
// output scaling, never a sound-logic fault.  See docs/AUDIT.md A12.
//
// Keep the multiply wide; an unsized 14-bit multiply silently truncated the
// product before the shift and produced distorted, seemingly random audio.
wire signed [18:0] mix_calc = $signed(sum) * 19'sd12;
wire signed [15:0] mix = mix_calc[15:0];
assign audio = (pause | reset) ? 16'sd0 : mix;

reg [7:0] cpu_din_r;
always @(*) begin
	cpu_din_r = 8'hFF;
	if (cpu_addr < 16'h2000)
		cpu_din_r = rom_q;
	else if (spr_cs)
		cpu_din_r = spr_dout;
	else if (shared_cs)
		cpu_din_r = shared_dout;
end
assign cpu_din = cpu_din_r;

wire _unused = cpu_rd | ce_sn1 | ce_sn2;

endmodule
