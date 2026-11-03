// exterm_crt -- core-side "CRT Adjust" (rmonic79 crt_adjust.sv, as pinned/adapted in the CRT reference
// core donors/simple156/vendor/crt_adjust) with Exterminator's read-rate generator.
//
// OSD controls (same ranges as simple156 OSMAN.sv):
//   CRT Adjust On/Off, H-Size (5-bit: 0,+1..+6,-10..-1), H-Position (-16..+15 px), V-Position (-16..+15 lines)
//
// Read-rate math.  Exterminator pixel = 4 clk_sys (20 MHz / 5 MHz).  The read CE ticks once every
// (BASE + hsize) sub-steps of 1/16 clk_sys:   BASE = 4 clk x 16 = 64 sub-steps
//   hsize = 0  -> period 64 sub-steps = exactly 4 clk  (native pixel pitch, integer & uniform)
//   hsize = +n -> slower read, wider pixels (n/64 = 1.56 % per step, same granularity as the
//                 96 MHz / 6 MHz reference core: 64 quarters)
//   hsize = -n -> faster read, narrower pixels; the minimum period 48 sub-steps = 3 clk keeps
//                 consecutive read ticks >= 3 clk apart (menu range -10 => 54 sub-steps = 3.4 clk) (arcade_video samples ce_pix rising edges).
// The accumulator resets on the rise of crt_adjust's hs_ref_out (NOT the raw HSync), the one wiring
// rule of the upstream docs.
//
// Exterminator geometry: HSync (10 clk) leads the line, picture 256 of 318 px sits at hcount
// 0x28..0x127 (about centred) -> HPOS_CONTENTSHIFT.  The line-buffer epoch is the upstream one
// "HS before picture" (vb_active delayed by one line), see rtl/fw/crt_adjust.sv header note.
//
// Pipeline latency (ce domain) is identical for r/g/b/hs/vs/hb/vb: they all leave the module together.
module exterm_crt #(
	parameter H_TOTAL = 318,    // single source of truth for the raster, shared with the HSync shreg size
	parameter V_TOTAL = 264
)(
	input        clk,           // clk_sys == CLK_VIDEO
	input        ce_pix,        // native pixel enable (1 in 4)
	input        crt_on,
	input  [4:0] hsize_code,    // OSD code 0..16 valid: 0..6 -> 0..+6, 7..16 -> -10..-1
	input signed [4:0] hpos,    // -16..+15
	input signed [4:0] vpos,    // -16..+15

	input  [7:0] r_in, g_in, b_in,
	input        hs_in, vs_in, hb_in, vb_in,    // hb_in: horizontal blank only, vb_in: vertical blank only

	output [7:0] r_out, g_out, b_out,
	output       hs_out, vs_out, hb_out, vb_out,
	output       ce_out         // CE to feed arcade_video (rising-edge sampled)
);

	// ---- decode H-Size exactly as OSMAN.sv ----
	wire signed [4:0] hsize = (hsize_code <= 5'd6)  ? $signed(hsize_code) :
	                          (hsize_code <= 5'd16) ? $signed(hsize_code - 5'd17) : 5'sd0;

	wire hs_ref;
	reg  hs_ref_d;
	always @(posedge clk) hs_ref_d <= hs_ref;
	wire hs_ref_rise = hs_ref & ~hs_ref_d;

	// period in 1/16 clk_sys: 64 + hsize  (48 .. 70 for the -10..+6 menu range)
	wire [6:0] rd_period = 7'd64 + {{2{hsize[4]}}, hsize};
	reg  [6:0] rd_acc;
	wire       rd_tick = ({1'b0, rd_acc} + 8'd16) >= {1'b0, rd_period};
	always @(posedge clk) begin
		if      (hs_ref_rise) rd_acc <= 7'd0;
		else if (rd_tick)     rd_acc <= rd_acc + 7'd16 - rd_period;
		else                  rd_acc <= rd_acc + 7'd16;
	end

	wire rd_ce = crt_on ? rd_tick : ce_pix;

	wire [7:0] c_r, c_g, c_b;
	wire       c_hs, c_vs, c_hb, c_vb;

	crt_adjust #(
		.VTOTAL    (V_TOTAL),
		.HTOTAL    (H_TOTAL),
		.HPOS_MODE (1)              // 1 = CONTENTSHIFT
	) u_crt_adjust (
		.clk       (clk),
		.pxl_cen   (ce_pix),
		.pxl2_cen  (rd_ce),
		.active    (crt_on),
		.hsize     (hsize),
		.hoffset   ({{4{hpos[4]}}, hpos}),
		.voffset   ({vpos[4], vpos}),
		.r_in      (r_in), .g_in(g_in), .b_in(b_in),
		.hs_in     (hs_in),
		.vs_in     (vs_in),
		.hb_in     (hb_in | vb_in),   // combined blank for the horizontal window edges
		.vb_in     (vb_in),           // true vertical blank (keeps the OSD vertical boundary)
		.r_out     (c_r), .g_out(c_g), .b_out(c_b),
		.hs_out    (c_hs), .vs_out(c_vs),
		.hb_out    (c_hb), .vb_out(c_vb),
		.hs_ref_out(hs_ref)
	);

	// Clean bypass when Off: identical to the native stream, no latency.
	assign r_out  = crt_on ? c_r  : r_in;
	assign g_out  = crt_on ? c_g  : g_in;
	assign b_out  = crt_on ? c_b  : b_in;
	assign hs_out = crt_on ? c_hs : hs_in;
	assign vs_out = crt_on ? c_vs : vs_in;
	assign hb_out = crt_on ? c_hb : hb_in;
	assign vb_out = crt_on ? c_vb : vb_in;
	assign ce_out = rd_ce;

endmodule
