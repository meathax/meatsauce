// Gondomania's 12-position rotary joystick for MiSTer (PLAN M4), one player.
//
// The board reads the rotary as a 12-bit one-hot code (d8_sys R_P1ROT*,
// dec8.cpp gondo_player_*_r); i_an0/i_an1 of d8_sys take MAME's AN port
// value, 0-11. MAME's port (dec8.cpp L1081-1085) is PORT_POSITIONS(12)
// PORT_WRAPS PORT_REVERSE with Z (decrement) and X (increment) for player 1,
// so the increment key lowers the value the game reads. Here "turn right"
// is MAME's increment key (X for player 1, M for player 2) and lowers `pos`;
// "turn left" (Z, N) raises it. Which way that turns the soldier on screen
// is what MAME's key assignment gives; not checked on a real controller.
//
// Three ways to turn, all active at once (no OSD switch needed):
//   buttons   Turn Left / Turn Right (keys or a gamepad): one step per
//             press, then repeated every 100 ms after 250 ms held
//   spinner   hps_io spinner: [7:0] signed delta, [8] toggles per report;
//             one step per i_spin_div counts (clockwise = turn right)
//   paddle    hps_io paddle, 0-255 absolute: when it changes, the position
//             is set to 11 - paddle * 12 / 256 (turning the paddle
//             clockwise turns right)
// Reset (download, OSD reset) returns to position 0, MAME's power-on value.

module d8_rotary #(
    parameter int CLK_HZ = 96000000
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       i_left,
    input  logic       i_right,
    input  logic [8:0] i_spinner,
    input  logic [7:0] i_paddle,
    input  logic [4:0] i_spin_div,       // spinner counts per step (4-16)
    output logic [3:0] o_pos
);

  localparam int T_FIRST = CLK_HZ / 4;    // 250 ms
  localparam int T_REP   = CLK_HZ / 10;   // 100 ms

  logic       l_q, r_q, sp_t;
  logic [7:0] pad_q;
  logic       pad_seen;
  logic [26:0] hold;
  logic signed [9:0] acc;

  wire held = i_left ^ i_right;           // both or neither: no turn
  wire press_l = i_left && !l_q && !i_right;
  wire press_r = i_right && !r_q && !i_left;
  wire rep = held && (hold == 27'(T_FIRST - 1));
  wire [11:0] pad12 = 12'(i_paddle) * 12'd12;
  wire signed [9:0] div  = {5'd0, i_spin_div};    // signed: acc compares signed
  wire signed [9:0] ndiv = -div;

  function automatic logic [3:0] cw(input logic [3:0] p);   // turn right
    return (p == 4'd0) ? 4'd11 : p - 4'd1;
  endfunction
  function automatic logic [3:0] ccw(input logic [3:0] p);  // turn left
    return (p == 4'd11) ? 4'd0 : p + 4'd1;
  endfunction

  always_ff @(posedge clk) begin
    l_q   <= i_left;
    r_q   <= i_right;
    sp_t  <= i_spinner[8];
    pad_q <= i_paddle;
    if (reset) begin
      o_pos    <= 4'd0;
      acc      <= '0;
      hold     <= '0;
      pad_seen <= 1'b0;
    end else begin
      // buttons, with repeat
      if (!held || press_l || press_r) hold <= '0;
      else if (rep) hold <= 27'(T_FIRST - T_REP);
      else hold <= hold + 27'd1;

      if (press_r || (rep && i_right)) o_pos <= cw(o_pos);
      else if (press_l || (rep && i_left)) o_pos <= ccw(o_pos);
      // spinner
      else if (i_spinner[8] != sp_t) acc <= acc + {{2{i_spinner[7]}}, i_spinner[7:0]};
      else if (acc >= div) begin
        acc   <= acc - div;
        o_pos <= cw(o_pos);
      end else if (acc <= ndiv) begin
        acc   <= acc + div;
        o_pos <= ccw(o_pos);
      end
      // paddle (ignored until it first moves: a missing paddle never moves)
      else if (i_paddle != pad_q) pad_seen <= 1'b1;
      else if (pad_seen) begin
        pad_seen <= 1'b0;
        o_pos    <= 4'd11 - pad12[11:8];
      end
    end
  end

endmodule
