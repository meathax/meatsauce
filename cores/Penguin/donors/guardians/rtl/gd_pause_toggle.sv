// Edge-triggered pause latch for a MiSTer-mappable controller button.
// SPDX-License-Identifier: GPL-3.0-or-later

module gd_pause_toggle
(
	input  logic clk,
	input  logic reset,
	input  logic button,
	output logic paused
);

logic button_d;

always_ff @(posedge clk) begin
	if (reset) begin
		button_d <= 1'b0;
		paused <= 1'b0;
	end
	else begin
		button_d <= button;
		if (button && !button_d) paused <= !paused;
	end
end

endmodule
