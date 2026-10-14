`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Executable CPU-board integration used by both the core and deterministic
// bus-level simulation.
module irobot_cpu_board (
	input logic clk_12m096, input logic reset,
	input logic irq_n, input logic firq_n,
	input logic rom_wr, input logic [16:0] rom_addr, input logic [7:0] rom_din,
	input logic [7:0] in0,in1,dsw1,
	input logic math_busy,video_busy,vblank,
	input logic [7:0] nvram_dout,adc_dout,pokey_dout,shared_dout,alpha_dout,
	output logic accepted, output logic [15:0] bus_addr,
	output logic [7:0] bus_din,bus_dout, output logic bus_rw,
	output logic [111:0] cpu_state,
	output logic nvram_cs,adc_start,pokey_cs,shared_cs,
	output logic nvram_we,pokey_we,palette_we,alpha_we,
	output logic [9:0] alpha_addr, output logic [7:0] alpha_data,
	output logic [1:0] adc_channel,
	output logic [7:0] statwr,out0,bankctl, output logic math_start,video_start
	,output logic irq_clear,output logic firq_clear
	// $1900-$19FF write decode (SP-251 3A net WDOG) -> 74LS90 7A R0 pins.
	,output logic wdclr
);
	logic e,q,ef,avma,launch_e,launch_q;
	// The board reset is generated in the 20 MHz/HPS shell domain, and IRQ,
	// FIRQ and the input ports are produced by master-clock logic that can
	// change on any phase. The 6809 core samples nRESET and the CPU data bus
	// on the falling edge of E and samples nIRQ/nFIRQ on the falling edge of
	// Q, so a launch register that can update on the very edge that samples
	// it leaves a zero-cycle path and fails hold. Every one of those signals
	// is therefore relaunched here under the phase-qualified enables, which
	// update two master ticks before the corresponding falling edge.
	// E/Q must keep running during reset so the processor can sample it;
	// board-local reset users retain their own boundary on the raw reset.
	logic cpu_reset, reset_pending;
	logic cpu_irq_n, cpu_firq_n;
	logic [7:0] cpu_in0, cpu_in1, cpu_dsw1;
	initial begin
		cpu_reset = 1'b1; reset_pending = 1'b1;
		cpu_irq_n = 1'b1; cpu_firq_n = 1'b1;
		cpu_in0 = 8'hff; cpu_in1 = 8'hff; cpu_dsw1 = 8'h00;
	end
	always_ff @(posedge clk_12m096) begin
		// cpu_reset can now only change once every eight master ticks, so a
		// reset that is asserted for fewer ticks than that would be dropped.
		// reset_pending makes the assertion sticky until the launch phase
		// consumes it, which stretches any pulse to a full E period and so
		// guarantees exactly one falling E edge with nRESET low.
		if (reset) reset_pending <= 1'b1;
		if (launch_e) begin
			cpu_reset <= reset | reset_pending;
			reset_pending <= reset;
			cpu_in0 <= in0; cpu_in1 <= in1; cpu_dsw1 <= dsw1;
		end
		if (launch_q) begin
			cpu_irq_n <= irq_n; cpu_firq_n <= firq_n;
		end
	end
	logic [7:0] board_din;
	/* verilator lint_off PINCONNECTEMPTY */
	irobot_cpu_phases phases(
		.clk_12m096(clk_12m096), .e(e), .q(q),
		.e_rise(), .e_fall(ef), .q_rise(), .q_fall(),
		.launch_e(launch_e), .launch_q(launch_q)
	);
	assign bus_din = board_din;

	irobot_cpu cpu(
		.reset(cpu_reset), .e(e), .q(q), .e_fall(ef), .irq_n(cpu_irq_n), .firq_n(cpu_firq_n),
		.halt_n(1'b1), .din(board_din), .dout(bus_dout), .addr(bus_addr), .rw(bus_rw),
		.avma(avma), .ba(), .bs(), .lic(), .cpu_state(cpu_state), .accepted(accepted)
	);
	irobot_mainboard board(
		.clk(clk_12m096), .reset(reset), .bus_valid(avma), .rw(bus_rw), .addr(bus_addr),
		.cpu_dout(bus_dout), .cpu_din(board_din), .in0(cpu_in0), .in1(cpu_in1), .dsw1(cpu_dsw1),
		.math_busy(math_busy), .video_busy(video_busy), .vblank(vblank), .nvram_dout(nvram_dout),
		.adc_dout(adc_dout), .pokey_dout(pokey_dout), .shared_dout(shared_dout), .alpha_dout(alpha_dout),
		.rom_wr(rom_wr), .rom_addr(rom_addr), .rom_din(rom_din), .nvram_cs(nvram_cs),
		.adc_start(adc_start), .pokey_cs(pokey_cs), .shared_cs(shared_cs), .nvram_we(nvram_we),
		.pokey_we(pokey_we), .adc_channel(adc_channel), .palette_we(palette_we), .alpha_we(alpha_we),
		.alpha_addr(alpha_addr), .alpha_data(alpha_data),
		.peripheral_din(), .statwr(statwr), .out0(out0), .bankctl(bankctl), .rom_bank(), .ram_bank(),
		.math_start(math_start), .video_start(video_start), .irq_clear(irq_clear), .firq_clear(firq_clear),
		.wdclr(wdclr)
	);
	/* verilator lint_on PINCONNECTEMPTY */
endmodule
