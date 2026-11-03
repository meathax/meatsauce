// DX-101 raster interrupt timing, including the held-line re-arm used by
// Guardians' two-line rowscroll effects.
// SPDX-License-Identifier: GPL-3.0-or-later

module gd_raster_irq
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_pix,
	input  logic [8:0]  h_count,
	input  logic [8:0]  v_count,
	input  logic        enable,
	input  logic [8:0]  position,
	// Pulses when software writes one to raster-enable. If the programmed
	// line is still current, the DX-101 interrupt line is still active and
	// the TMP68301 queues a second service after the first handler returns.
	input  logic        rearm,
	output logic        irq
);

always_ff @(posedge clk) begin
	irq <= 1'b0;
	if (!reset) begin
		if (ce_pix && enable && (h_count == 9'd0)
		    && (v_count == position))
			irq <= 1'b1;

		if (rearm && (v_count == position))
			irq <= 1'b1;
	end
end

endmodule
