// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// Trackball axis for Ataxx from a D-pad, an analog stick, a spinner or a mouse. Like MAME's
// IPT_TRACKBALL with PORT_KEYDELTA(4) at 80% sensitivity, a held D-pad direction adds a
// small fixed step every frame (no ramp, stops when released); the stick adds a step
// proportional to its deflection beyond a dead zone. The result is a free-running
// mod-256 position, read back by the game as a change since its last read. Spinner and
// mouse deltas are added as they arrive.

module trackball_input
(
	input              clk_sys,
	input              reset,
	input              ce_frame,    // one-cycle pulse, once per video frame

	input  signed [7:0] analog,     // -128..127, 0 = centered
	input              dpad_neg,
	input              dpad_pos,
	input        [8:0] spinner,     // [8] toggles on each update, [7:0] signed delta
	input        [8:0] mouse,       // same format as spinner
	input              mouse_invert, // negate the mouse delta (PS/2 Y points up)

	output       [7:0] pos
);

	localparam signed [8:0] DPAD_STEP = 9'sd3;
	localparam        [7:0] DEADZONE  = 8'd24;

	wire signed [8:0] dpad_term = dpad_pos ? DPAD_STEP : (dpad_neg ? -DPAD_STEP : 9'sd0);

	wire        [7:0] mag = analog[7] ? (8'd0 - analog) : analog;
	wire        [7:0] over = (mag > DEADZONE) ? (mag - DEADZONE) : 8'd0;
	wire signed [8:0] scaled = {1'b0, over[7:4]}; // 0..6 counts per frame
	wire signed [8:0] analog_term = analog[7] ? -scaled : scaled;

	reg       spinner_toggle_d, mouse_toggle_d;
	reg [7:0] accum;

	wire [7:0] spin_add  = (spinner[8] != spinner_toggle_d) ? spinner[7:0] : 8'h00;
	wire [7:0] mouse_raw = (mouse[8] != mouse_toggle_d) ? mouse[7:0] : 8'h00;
	wire [7:0] mouse_add = mouse_invert ? (8'd0 - mouse_raw) : mouse_raw;
	wire [7:0] frame_add = ce_frame ? (dpad_term[7:0] + analog_term[7:0]) : 8'h00;

	always @(posedge clk_sys) begin
		if (reset) begin
			accum            <= 8'h00;
			spinner_toggle_d <= 1'b0;
			mouse_toggle_d   <= 1'b0;
		end else begin
			spinner_toggle_d <= spinner[8];
			mouse_toggle_d   <= mouse[8];
			accum            <= accum + spin_add + mouse_add + frame_add;
		end
	end

	assign pos = accum;

endmodule
