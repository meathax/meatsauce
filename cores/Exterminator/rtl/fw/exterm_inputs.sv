// exterm_inputs -- MiSTer pads + PS/2 keyboard -> Exterminator cabinet inputs.
//
// MAME exterm input words (active low), see exterm.cpp INPUT_PORTS_START(exterm):
//   P1 : b0 COIN1   b1 START1  b2 UP  b3 DOWN  b4 LEFT  b5 RIGHT  b6 BUTTON2  b7 BUTTON1
//        b13:8 trackball data (merged inside the core from dial_p1)  b14 unused  b15 SERVICE
//   P2 : b0 COIN2   b1 START2  b2..b5 stick, b6 BUTTON2, b7 BUTTON1, b13:8 trackball, b15:14 unused
//
// Function names come from the game's own Test Menu > "Player Switch Test" screen
// (MAME 0.289 capture, build/hiscore/snap): BUTTON1 (0x80) lights "JOYSTICK FIRE",
// BUTTON2 (0x40) lights "POUND", the dial is "ROTATE" and the players are
// "LEFT PLAYER" (P1) / "RIGHT PLAYER" (P2).  Hence: Fire, Pound, Rotate Left/Right.
//
// MiSTer pad bit layout (CONF_STR "J1,Fire,Pound,Rotate Left,Rotate Right,Start,Coin,Service"):
//   [0] right [1] left [2] down [3] up [4] Fire [5] Pound [6] Rotate Left [7] Rotate Right
//   [8] Start [9] Coin [10] Service; higher pad bits are ignored
module exterm_inputs (
	input             clk,
	input             rst,
	input      [31:0] joy0,
	input      [31:0] joy1,
	input      [10:0] ps2_key,      // [10] toggle [9] pressed [8] extended [7:0] set-2 scancode
	input             svc_opt,      // OSD "Service switch" (level)

	output     [15:0] in_p1,        // active low, MAME P1 layout (dial bits 13:8 forced to 1)
	output     [15:0] in_p2,        // active low, MAME P2 layout
	output            rot_inc_p1,   // held: rotate (aim) increasing, keyboard X / pad Rotate Right
	output            rot_dec_p1,   //       decreasing, keyboard Z / pad Rotate Left
	output            rot_inc_p2,   // keyboard M
	output            rot_dec_p2    // keyboard N
);

	// ------------------------------------------------------------------
	// Keyboard state (set-2 scancodes, MAME default key names)
	// ------------------------------------------------------------------
	reg k_coin1, k_coin2, k_start1, k_start2;
	reg k_up1, k_dn1, k_lf1, k_rt1, k_f1, k_p1;       // arrows, LCtrl (fire), LAlt (pound)
	reg k_up2, k_dn2, k_lf2, k_rt2, k_f2, k_p2;       // R F D G, A (fire), S (pound)
	reg k_z, k_x, k_n, k_m;                           // dial dec/inc (MAME KEYCODE_Z/X, N/M)
	reg svc_tog;                                      // F2 / pad Service toggle (MAME service switch is a toggle)
	reg old_tog;

	wire        pressed  = ps2_key[9];
	wire        ext      = ps2_key[8];
	wire  [7:0] code     = ps2_key[7:0];
	wire        key_evt  = (ps2_key[10] != old_tog);

	always @(posedge clk) begin
		old_tog <= ps2_key[10];
		if (rst) begin
			{k_coin1,k_coin2,k_start1,k_start2} <= 4'd0;
			{k_up1,k_dn1,k_lf1,k_rt1,k_f1,k_p1} <= 6'd0;
			{k_up2,k_dn2,k_lf2,k_rt2,k_f2,k_p2} <= 6'd0;
			{k_z,k_x,k_n,k_m} <= 4'd0;
		end
		else if (key_evt) begin
			case ({ext, code})
				9'h02E: k_coin1  <= pressed;   // 5
				9'h036: k_coin2  <= pressed;   // 6
				9'h016: k_start1 <= pressed;   // 1
				9'h01E: k_start2 <= pressed;   // 2
				9'h175: k_up1    <= pressed;   // arrow up
				9'h172: k_dn1    <= pressed;   // arrow down
				9'h16B: k_lf1    <= pressed;   // arrow left
				9'h174: k_rt1    <= pressed;   // arrow right
				9'h014: k_f1     <= pressed;   // left ctrl  : P1 Fire (MAME BUTTON1)
				9'h011: k_p1     <= pressed;   // left alt   : P1 Pound (MAME BUTTON2)
				9'h02D: k_up2    <= pressed;   // R
				9'h02B: k_dn2    <= pressed;   // F
				9'h023: k_lf2    <= pressed;   // D
				9'h034: k_rt2    <= pressed;   // G
				9'h01C: k_f2     <= pressed;   // A          : P2 Fire
				9'h01B: k_p2     <= pressed;   // S          : P2 Pound
				9'h01A: k_z      <= pressed;   // Z          : P1 dial decrement
				9'h022: k_x      <= pressed;   // X          : P1 dial increment
				9'h031: k_n      <= pressed;   // N          : P2 dial decrement
				9'h03A: k_m      <= pressed;   // M          : P2 dial increment
				default: ;
			endcase
		end
	end

	// Service switch toggle on F2 or the pad Service button.
	reg old_pad_svc;
	wire pad_svc = joy0[10] | joy1[10];
	always @(posedge clk) begin
		old_pad_svc <= pad_svc;
		if (rst) svc_tog <= 1'b0;
		else begin
			if (key_evt && pressed && !ext && code == 8'h06) svc_tog <= ~svc_tog;
			if (pad_svc && !old_pad_svc) svc_tog <= ~svc_tog;
		end
	end

	wire service = svc_opt | svc_tog;

	// ------------------------------------------------------------------
	// Cabinet words
	// ------------------------------------------------------------------
	wire up1 = joy0[3] | k_up1, dn1 = joy0[2] | k_dn1, lf1 = joy0[1] | k_lf1, rt1 = joy0[0] | k_rt1;
	wire up2 = joy1[3] | k_up2, dn2 = joy1[2] | k_dn2, lf2 = joy1[1] | k_lf2, rt2 = joy1[0] | k_rt2;
	wire fire1  = joy0[4] | k_f1, pound1 = joy0[5] | k_p1;
	wire fire2  = joy1[4] | k_f2, pound2 = joy1[5] | k_p2;
	wire coin1  = joy0[9] | k_coin1, start1 = joy0[8] | k_start1;
	wire coin2  = joy1[9] | k_coin2, start2 = joy1[8] | k_start2;

	assign in_p1 = ~{service, 1'b0, 6'b000000, fire1, pound1, rt1, lf1, dn1, up1, start1, coin1} | 16'h3F00;
	assign in_p2 = ~{1'b0, 1'b0, 6'b000000, fire2, pound2, rt2, lf2, dn2, up2, start2, coin2} | 16'h3F00;

	assign rot_inc_p1 = joy0[7] | k_x;
	assign rot_dec_p1 = joy0[6] | k_z;
	assign rot_inc_p2 = joy1[7] | k_m;
	assign rot_dec_p2 = joy1[6] | k_n;

endmodule
