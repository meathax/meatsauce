// exterm_aim -- one player's "Rotate" (aim) dial for Exterminator.
//
// MAME model (exterm.cpp): port DIAL0/DIAL1 = IPT_DIAL, 8-bit absolute counter, PORT_REVERSE,
// PORT_SENSITIVITY(50) PORT_KEYDELTA(10) (Z/X, N/M).  trackball_port_r() computes
//     diff = old_pos - pos ;  aimpos = (aimpos + diff) & 0x3f
// so with PORT_REVERSE (pos = -accum) increasing the physical accumulator A by d raises the
// 6-bit aim count by d.  This block keeps A and outputs dial = (0 - A) [8 bit], i.e. exactly the
// value the REVERSEd MAME port would present to exterm_core's  diff = old - pos.
//
// Sources (all summed): keyboard / pad "Rotate Left/Right" (counts per ~60 Hz tick), HPS spinner
// (signed delta events), HPS paddle (absolute 0..255 -> delta), PS/2 mouse X (selected player only)
// and optional analog stick X (rate).  Spinner/paddle/mouse use a sensitivity multiplier in
// quarter units (x1/4 .. x4) with a retained fractional remainder so slow motion is not lost.
//
// Contract with exterm_core: the game polls the dial once per frame; deltas per poll must stay
// within +-127 (8-bit wrap), so very fast mouse flicks at x4 can alias.
module exterm_aim (
	input             clk,
	input             rst,
	input             tick,          // ~60 Hz enable (one clk pulse)
	input             rev,           // reverse aim direction
	input       [2:0] sens,          // multiplier select, see table
	input       [1:0] key_speed,     // counts per tick for Rotate buttons: 2,3,5,8
	input             key_inc,
	input             key_dec,
	input       [8:0] spinner,       // hps_io spinner_N: [8] toggles per update, [7:0] signed delta
	input       [7:0] paddle,        // hps_io paddle_N 0..255 absolute
	input             mouse_ev,      // one-clk pulse per mouse packet (already gated by player select)
	input signed [8:0] mouse_dx,
	input             analog_en,
	input signed [7:0] analog_x,
	output     [7:0]  dial
);

	// ---- multiplier in 1/4 units (OSD order: x1 x0.5 x0.25 x2 x3 x4 x1.5 x0.75, default x1) ----
	reg [4:0] mult;
	always @* case (sens)
		3'd0: mult = 5'd4;
		3'd1: mult = 5'd2;
		3'd2: mult = 5'd1;
		3'd3: mult = 5'd8;
		3'd4: mult = 5'd12;
		3'd5: mult = 5'd16;
		3'd6: mult = 5'd6;
		default: mult = 5'd3;
	endcase

	// ---- per-tick sources: buttons + analog stick ----
	reg [3:0] kspd;                       // OSD order 5,8,3,2 (default 5 = MAME KEYDELTA 10 x 50 %)
	always @* case (key_speed)
		2'd0: kspd = 4'd5;
		2'd1: kspd = 4'd8;
		2'd2: kspd = 4'd3;
		default: kspd = 4'd2;
	endcase

	wire signed [5:0] k_inc = key_inc ? $signed({2'b00, kspd}) : 6'sd0;
	wire signed [5:0] k_dec = key_dec ? $signed({2'b00, kspd}) : 6'sd0;
	wire signed [5:0] k_del = k_inc - k_dec;

	// analog stick: dead zone +-12, rate = x/16 (+-7 counts per tick at full throw)
	wire signed [7:0] ax = analog_x;
	wire        ax_out = (ax > 8'sd12) || (ax < -8'sd12);
	wire signed [7:0] a_del = (analog_en && ax_out) ? (ax >>> 4) : 8'sd0;

	wire signed [9:0] tick_del_raw = $signed({{4{k_del[5]}}, k_del}) + $signed({{2{a_del[7]}}, a_del});
	wire signed [9:0] tick_del = tick ? (rev ? -tick_del_raw : tick_del_raw) : 10'sd0;

	// ---- event sources: spinner, paddle, mouse ----
	reg [8:0] spin_d;
	reg [7:0] pad_d;
	reg       primed;
	always @(posedge clk) begin
		spin_d <= spinner;
		pad_d  <= paddle;
		primed <= ~rst;                 // first sample after reset only primes pad_d
	end
	wire        spin_ev = primed && (spinner[8] != spin_d[8]);
	wire signed [8:0] spin_del = spin_ev ? $signed({spinner[7], spinner[7:0]}) : 9'sd0;
	wire signed [7:0] pad_diff = paddle - pad_d;                   // wraps -> signed delta
	wire signed [8:0] pad_del  = (primed && paddle != pad_d) ? $signed({pad_diff[7], pad_diff}) : 9'sd0;
	wire signed [8:0] mou_del  = mouse_ev ? mouse_dx : 9'sd0;

	wire signed [10:0] src_raw = $signed({{2{spin_del[8]}}, spin_del}) +
	                             $signed({{2{pad_del[8]}},  pad_del})  +
	                             $signed({{2{mou_del[8]}},  mou_del});
	wire signed [10:0] src     = rev ? -src_raw : src_raw;

	// scaled = src * mult  (mult 1..16, quarter units); keep 2 fractional bits across events
	wire signed [16:0] scaled = src * $signed({1'b0, mult});
	reg         [1:0]  frac;
	wire signed [17:0] tot    = {scaled[16], scaled} + $signed({16'd0, frac});
	wire signed [15:0] ev_int = tot[17:2];                          // floor(tot / 4)

	reg [7:0] accum;                                                // physical accumulator A
	always @(posedge clk) begin
		if (rst) begin
			accum <= 8'd0;
			frac  <= 2'd0;
		end else begin
			frac  <= tot[1:0];
			accum <= accum + ev_int[7:0] + tick_del[7:0];
		end
	end

	assign dial = 8'd0 - accum;                                     // PORT_REVERSE applied here

endmodule
