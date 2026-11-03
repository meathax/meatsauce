// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

//============================================================================
//  steering_input — combines MiSTer's three steering control schemes
//  (analog joystick, digital d-pad, spinner) into one free-running 8-bit
//  "virtual dial" position.
//
//  The cabinet's wheel is a free-spinning rotary encoder (MAME IPT_DIAL): only the change
//  between two reads matters. All three input styles are added into one free-running
//  mod-256 accumulator, so they can be mixed freely.
//============================================================================

module steering_input
(
	input              clk_sys,
	input              reset,
	input              ce_frame,       // one-cycle pulse, once per video frame

	input              dpad_pos_mode,  // OSD: 0 = velocity ramp (default), 1 = position ramp w/ spring-return
	input  signed [7:0] analog_x,      // joystick_l_analog X, signed -128..127, 0 = centered
	input              dpad_left,
	input              dpad_right,
	input        [8:0] spinner,        // hps_io spinner_N: [8] = toggle (flips each update), [7:0] = signed delta

	output       [7:0] wheel_pos       // free-running accumulator -> leland_board's p*_wheel port
);

	// Ramp: full accel/decel over ~8 frames. Deflection is scaled down (>>>3) so a held
	// d-pad and full analog deflection reach a comparable top turn rate.
	localparam signed [8:0] RAMP_STEP = 9'sd16;
	localparam signed [8:0] VEL_MAX   = 9'sd16;
	localparam signed [8:0] POS_MAX   = 9'sd127;

	reg signed [8:0] velocity; // velocity-mode ramp state
	reg signed [8:0] deflect;  // position-mode virtual stick deflection (spring-return)

	wire signed [8:0] dpad_dir = dpad_right ? 9'sd1 : (dpad_left ? -9'sd1 : 9'sd0);

	always @(posedge clk_sys) begin
		if (reset) begin
			velocity <= 9'sd0;
			deflect  <= 9'sd0;
		end else if (ce_frame) begin
			if (dpad_dir > 0)      velocity <= (velocity + RAMP_STEP > VEL_MAX) ? VEL_MAX : velocity + RAMP_STEP;
			else if (dpad_dir < 0) velocity <= (velocity - RAMP_STEP < -VEL_MAX) ? -VEL_MAX : velocity - RAMP_STEP;
			else if (velocity > 0) velocity <= (velocity - RAMP_STEP < 0) ? 9'sd0 : velocity - RAMP_STEP;
			else if (velocity < 0) velocity <= (velocity + RAMP_STEP > 0) ? 9'sd0 : velocity + RAMP_STEP;

			if (dpad_dir > 0)      deflect <= (deflect + RAMP_STEP > POS_MAX) ? POS_MAX : deflect + RAMP_STEP;
			else if (dpad_dir < 0) deflect <= (deflect - RAMP_STEP < -POS_MAX) ? -POS_MAX : deflect - RAMP_STEP;
			else if (deflect > 0)  deflect <= (deflect - RAMP_STEP < 0) ? 9'sd0 : deflect - RAMP_STEP;
			else if (deflect < 0)  deflect <= (deflect + RAMP_STEP > 0) ? 9'sd0 : deflect + RAMP_STEP;
		end
	end

	wire signed [8:0] dpad_contribution   = dpad_pos_mode ? (deflect >>> 3) : velocity;
	wire signed [8:0] analog_contribution = $signed({analog_x[7], analog_x}) >>> 3;

	reg       spinner_toggle_d;
	reg [7:0] accum;

	// Mod-256 add: wraps correctly whether the operand is signed or unsigned.
	wire [7:0] spin_add = (spinner[8] != spinner_toggle_d) ? spinner[7:0] : 8'h00;
	wire [7:0] frame_add = ce_frame ? (dpad_contribution[7:0] + analog_contribution[7:0]) : 8'h00;

	always @(posedge clk_sys) begin
		if (reset) begin
			accum            <= 8'h00;
			spinner_toggle_d <= 1'b0;
		end else begin
			spinner_toggle_d <= spinner[8];
			accum            <= accum + spin_add + frame_add;
		end
	end

	assign wheel_pos = accum;

endmodule
