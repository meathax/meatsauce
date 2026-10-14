//============================================================================
//  ym2151_wrap.sv -- Williams-board adapter for IKAOPM
//
//  IKAOPM is a die-shot-derived YM2151 implementation. The board-facing
//  interface stays unchanged: 3.579545 MHz clock enable, active-low reset,
//  physical /IRQ level, status byte, and signed YM3012-style stereo samples.
//============================================================================

`default_nettype none

module ym2151_wrap #(
	parameter FULL_RES = 0
) (
	input  logic               clk,
	input  logic               ce,
	input  logic               rst_n,
	input  logic               cs_n,
	input  logic               wr_n,
	input  logic               a0,
	input  logic [7:0]         din,
	output logic [7:0]         dout,
	output logic               irq_n,
	output logic signed [15:0] sample_l,
	output logic signed [15:0] sample_r,
	output logic               sample_valid
);

	logic bus_wr, bus_wr_q;
	logic write_active, write_waiting, write_armed;
	logic [1:0] write_hold, write_phi_wait;
	logic write_a0;
	logic [7:0] write_data;

	assign bus_wr = ~cs_n & ~wr_n;

	// FULLY_SYNCHRONOUS adds two input synchronizer stages. Keep each request
	// stable for four host clocks, then leave four phi clocks for the donor's
	// internal request latch to retire before accepting another write.
	always_ff @(posedge clk) begin
		bus_wr_q <= bus_wr;
		if (!rst_n) begin
			bus_wr_q       <= 1'b0;
			write_active   <= 1'b0;
			write_waiting  <= 1'b0;
			write_armed    <= 1'b1;
			write_hold     <= 2'd0;
			write_phi_wait <= 2'd0;
			write_a0       <= 1'b0;
			write_data     <= 8'h00;
		end else if (write_waiting) begin
			if (ce) begin
				if (write_phi_wait == 2'd3) begin
					write_waiting <= 1'b0;
					write_armed   <= 1'b1;
				end else begin
					write_phi_wait <= write_phi_wait + 1'b1;
				end
			end
		end else if (write_active) begin
			if (write_hold == 2'd3) begin
				write_active   <= 1'b0;
				write_waiting  <= 1'b1;
				write_phi_wait <= 2'd0;
			end else begin
				write_hold <= write_hold + 1'b1;
			end
		end else if (bus_wr && !bus_wr_q && write_armed) begin
			write_active <= 1'b1;
			write_armed  <= 1'b0;
			write_hold   <= 2'd0;
			write_a0     <= a0;
			write_data   <= din;
		end
	end

`ifndef SYNTHESIS
	always_ff @(posedge clk) begin
		if (rst_n && bus_wr && !bus_wr_q && !write_armed)
			$error("IKAOPM host write arrived before prior write retired");
	end
`endif

	logic sample_strobe_l, sample_strobe_r;
	logic signed [15:0] ika_l, ika_r, ika_l_ex, ika_r_ex;
	logic signed [15:0] selected_l, selected_r;

	assign selected_l = (FULL_RES != 0) ? ika_l_ex : ika_l;
	assign selected_r = (FULL_RES != 0) ? ika_r_ex : ika_r;

	// The physical YM3012 channels latch at different pipeline phases. Preserve
	// both boundaries; sample_valid uses the left-channel cadence (phi/64).
	always_ff @(posedge clk) begin
		if (!rst_n) begin
			sample_l     <= 16'sd0;
			sample_r     <= 16'sd0;
			sample_valid <= 1'b0;
		end else begin
			sample_valid <= sample_strobe_l;
			if (sample_strobe_l) sample_l <= selected_l;
			if (sample_strobe_r) sample_r <= selected_r;
		end
	end

	// Williams leaves CT1/CT2 unused. SH1/SH2/SO feed the physical YM3012;
	// this FPGA boundary consumes the donor's reconstructed stereo outputs.
	// o_D is continuous status, so neither the external output-enable nor a read
	// strobe is needed by the caller's already-decoded input mux.
	IKAOPM #(
		.FULLY_SYNCHRONOUS (1),
		.FAST_RESET        (1),
		.USE_BRAM          (0)
	) u_ikaopm (
		.i_EMUCLK       (clk),
		.i_phiM_PCEN_n  (~ce),
		.i_IC_n         (rst_n),
		.o_phi1         (),
		.i_CS_n         (~write_active),
		.i_RD_n         (1'b1),
		.i_WR_n         (~write_active),
		.i_A0           (write_a0),
		.i_D            (write_data),
		.o_D            (dout),
		.o_D_OE         (),
		.o_CT1          (),
		.o_CT2          (),
		.o_IRQ_n        (irq_n),
		.o_SH1          (),
		.o_SH2          (),
		.o_SO           (),
		.o_EMU_R_SAMPLE (sample_strobe_r),
		.o_EMU_R_EX     (ika_r_ex),
		.o_EMU_R        (ika_r),
		.o_EMU_L_SAMPLE (sample_strobe_l),
		.o_EMU_L_EX     (ika_l_ex),
		.o_EMU_L        (ika_l)
	);

endmodule

`default_nettype wire
