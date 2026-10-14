//============================================================================
// Indoor/American Soccer MSM5205 sample controller.
//
// Matches MAME's idsoccer_state edge semantics:
//   D7 falling stops, D6 falling starts (start wins if both happen together)
//   D1:D0 select one 0x4000-byte / 0x8000-nibble bank
//   high nibble is emitted before low nibble
//============================================================================
module docastle_adpcm
(
	input               clk,
	input               reset,
	input               pause,
	input               enabled,
	input               control_wr,
	input         [7:0] control_data,
	output        [7:0] status,

	output       [15:0] rom_addr,
	input         [7:0] rom_q,

	output signed [11:0] sound,
	output              busy_debug,
	output       [17:0] nibble_pos_debug,
	output              nibble_strobe_debug
);

reg [7:0] control;
reg idle;
reg [17:0] nibble_pos;
reg [17:0] nibble_end;

wire stop_edge = control_wr && control[7] && !control_data[7];
wire start_edge = control_wr && control[6] && !control_data[6];
wire [17:0] selected_start = {1'b0,control_data[1:0],15'b0};

assign status = idle ? 8'h00 : 8'h80;
assign busy_debug = !idle;
assign nibble_pos_debug = nibble_pos;
assign rom_addr = nibble_pos[16:1];

// 49.152 MHz / 128 = the board's exact 384 kHz MSM5205 input clock.
reg [6:0] cen_div;
reg ce_384k;
always @(posedge clk) begin
	if (reset) begin
		cen_div <= 0;
		ce_384k <= 0;
	end else begin
		ce_384k <= 0;
		if (cen_div == 7'd127) begin
			cen_div <= 0;
			ce_384k <= !pause;
		end else cen_div <= cen_div + 1'd1;
	end
end

wire [3:0] adpcm_din = nibble_pos[0] ? rom_q[3:0] : rom_q[7:4];
wire vclk_irq;
wire sample_unused;
wire vclk_unused;

jt5205 #(.INTERPOL(0), .VCLK_CEN(1)) decoder
(
	.rst(reset | idle | !enabled),
	.clk(clk),
	.cen(ce_384k),
	.sel(2'd2),
	.din(adpcm_din),
	.sound(sound),
	.sample(sample_unused),
	.irq(vclk_irq),
	.vclk_o(vclk_unused)
);

assign nibble_strobe_debug = vclk_irq && !idle && enabled;

always @(posedge clk) begin
	if (reset || !enabled) begin
		control <= 0;
		idle <= 1;
		nibble_pos <= 0;
		nibble_end <= 0;
	end else begin
		// Reset on the master clock immediately after the final valid nibble.
		if (!idle && (nibble_pos >= nibble_end))
			idle <= 1;

		if (vclk_irq && !idle && !pause)
			nibble_pos <= nibble_pos + 1'd1;

		if (control_wr) begin
			if (stop_edge)
				idle <= 1;

			// This is intentionally after stop so a simultaneous pair of
			// falling edges follows MAME's start-wins ordering.
			if (start_edge) begin
				nibble_pos <= selected_start;
				nibble_end <= selected_start + 18'h08000;
				idle <= 0;
			end

			control <= control_data;
		end
	end
end

wire _unused = sample_unused | vclk_unused;

endmodule
