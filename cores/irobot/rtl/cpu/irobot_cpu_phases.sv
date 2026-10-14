`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// SP-251 sheet 3B CPU phase divider. A 12.096 MHz board clock produces
// 1.512 MHz quadrature E/Q signals with Q leading E by two master ticks.
module irobot_cpu_phases (
	input logic clk_12m096,
	output logic e, output logic q,
	output logic e_rise, output logic e_fall, output logic q_rise, output logic q_fall,
	// Master-clock write enables for registers whose output is sampled by the
	// 6809 core on a falling E or Q edge. Using them puts the launching edge
	// two master ticks before the capturing edge, so setup and hold each keep
	// a full master period of margin and the timing analyser no longer sees a
	// zero-cycle master-clock to E or master-clock to Q path.
	output logic launch_e, output logic launch_q
);
	logic [2:0] phase;
	logic e_next,q_next;
	// SP-251 3B: 7E clear/load are inactive; board reset does not stop E/Q.
	initial begin phase=0;e=0;q=0;e_rise=0;e_fall=0;q_rise=0;q_fall=0;end
	always_comb begin
		q_next = (phase < 3'd4);
		e_next = (phase >= 3'd2) && (phase < 3'd6);
	end
	// E and Q are registered, so the published waveform runs one master tick
	// behind the combinational terms above. E is high while phase holds 3 to 6
	// and falls on the phase 6 to 7 edge; Q is high while phase holds 1 to 4
	// and falls on the phase 4 to 5 edge. The enables therefore fire at phase
	// 4 and phase 2, two master edges before the respective falling edge.
	assign launch_e = (phase == 3'd4);
	assign launch_q = (phase == 3'd2);
	always @(posedge clk_12m096) begin
		e_rise<=e_next&&!e; e_fall<=!e_next&&e; q_rise<=q_next&&!q; q_fall<=!q_next&&q;
		e<=e_next; q<=q_next; phase<=phase+1'd1;
	end
endmodule
