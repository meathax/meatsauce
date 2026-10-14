// SPDX-License-Identifier: GPL-3.0-or-later
// Board-specific wrapper. E and Q are explicit phase signals; no read-cycle
// AVMA override is applied.
module irobot_cpu (
	input logic reset, input logic e, input logic q, input logic e_fall,
	input logic irq_n, input logic firq_n, input logic halt_n,
	input logic [7:0] din,
	output logic [7:0] dout, output logic [15:0] addr, output logic rw,
	output logic avma, output logic ba, output logic bs, output logic lic,
	output logic [111:0] cpu_state,
	output logic accepted
);
	/* verilator lint_off PINCONNECTEMPTY */
	mc6809e cpu(
		.D(din), .DOut(dout), .ADDR(addr), .RnW(rw), .E(e), .Q(q),
		.BS(bs), .BA(ba), .nIRQ(irq_n), .nFIRQ(firq_n), .nNMI(1'b1),
		.AVMA(avma), .BUSY(), .LIC(lic), .nHALT(halt_n), .nRESET(~reset),
		.RegData(cpu_state)
	);
	/* verilator lint_on PINCONNECTEMPTY */
	// Every E falling edge completes the bus cycle presented by the 6809E.
	// AVMA/BUSY qualify board-side ownership and wait-state behavior, but
	// filtering on them hides reset-vector and operand cycles from the
	// canonical bus observer even though the CPU samples those cycles.
	assign accepted = e_fall;
endmodule
