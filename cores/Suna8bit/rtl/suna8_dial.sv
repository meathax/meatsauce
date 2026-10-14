//============================================================================
//  SunA8bit -- Brick Zone spinner / paddle / mouse input (profile 5 only)
//
//  Input capture is adapted from tempest_spinner.sv in
//  MiSTer-devel/Arcade-Tempest_MiSTer (written 2026 by Videodr0me, GNU GPL
//  v2): registered hps_io inputs, a first-sample synchronisation so power-up
//  values never count as movement, exactly one event per hps_io toggle bit
//  (spinner_N[8], ps2_mouse[24]), sign extension of the 8-bit spinner and
//  9-bit mouse deltas, a per-setting gain table, and a saturating
//  pending-movement counter drained at the game's own sampling cadence.
//  This file is distributed under the same GNU GPL v2 terms.
//
//  Two outputs, because the two Brick Zone program families read different
//  ports (MAME 0.289 read taps and debugger disassembly, VERIFICATION R081):
//
//  * dial_1 / dial_2 -- MAME's SPIN1/SPIN2 IPT_DIAL ports at $C108/$C10C:
//    an 8-bit wrapping position, PORT_REVERSE'd, idle 0xFF. Only the spinner
//    program (brickznv4/brickzn11) reads them, once per frame (v4 0x33B4).
//  * emu_left / emu_right -- the v6.0 joystick program (the brickzn parent,
//    the only Brick Zone set this core loads) never reads $C108/$C10C; it
//    moves the paddle 5 pixels in every frame left/right is held (work RAM
//    $D22C). Movement is converted into whole frames of left/right, one
//    5-pixel step per frame, like a position servo. The caller ORs these
//    into the joystick bits, so the joystick keeps working unchanged.
//
//  Gains at the 1x setting: one spinner count = one pixel, one paddle unit
//  (0..255 absolute) = one pixel, one mouse count = half a pixel (the
//  Tempest donor's mouse base gain). MiSTer Main sends a mouse-as-spinner
//  device's movement as both a spinner delta and an accumulated paddle
//  value (Main_MiSTer input.cpp, QUIRK_MSSP), so paddle movement is ignored
//  for 63 frames after any spinner event on the same player.
//============================================================================
module suna8_dial #(
    // One frame of held left/right in Q4 pixels: brickzn v6.0 = 5 px/frame.
    parameter logic signed [17:0] STEP_Q4 = 18'sd80,
    // Pending movement cap, Q4 pixels: four frames of motion.
    parameter logic signed [17:0] MAX_Q4  = 18'sd320
)(
    input  logic       clk,
    input  logic       reset,
    input  logic       enable,        // profile 5 (Brick Zone) only
    input  logic       vblank,        // frame cadence for the joystick servo
    input  logic [8:0] spinner_1,     // hps_io: [7:0] signed delta, [8] toggle
    input  logic [8:0] spinner_2,
    input  logic [7:0] paddle_1,      // hps_io: absolute 0..255
    input  logic [7:0] paddle_2,
    input  logic       mouse_toggle,  // ps2_mouse[24]
    input  logic [8:0] mouse_dx,      // {ps2_mouse[4], ps2_mouse[15:8]}
    input  logic [1:0] sensitivity,   // 0: 1x, 1: 2x, 2: 4x, 3: 0.5x
    output logic [7:0] dial_1,        // $C108 read value
    output logic [7:0] dial_2,        // $C10C read value
    output logic [1:0] emu_left,      // [0] P1, [1] P2; held for a frame
    output logic [1:0] emu_right
);

    // Q4 pixels from half-pixel units at the selected gain.
    function automatic logic signed [17:0] gain_q4(
        input logic signed [11:0] half_px,
        input logic        [1:0]  setting
    );
        logic signed [17:0] x;
        begin
            x = {{6{half_px[11]}}, half_px};
            case (setting)
                2'd1:    gain_q4 = x <<< 4; // 2x
                2'd2:    gain_q4 = x <<< 5; // 4x
                2'd3:    gain_q4 = x <<< 2; // 0.5x
                default: gain_q4 = x <<< 3; // 1x: 8 Q4 units per half pixel
            endcase
        end
    endfunction

    function automatic logic signed [17:0] saturate(input logic signed [17:0] v);
        begin
            if (v > MAX_Q4)
                saturate = MAX_Q4;
            else if (v < -MAX_Q4)
                saturate = -MAX_Q4;
            else
                saturate = v;
        end
    endfunction

    // Registered inputs.
    logic       vblank_q, vblank_q2;
    logic [8:0] spin_q [0:1];
    logic [7:0] pad_q  [0:1];
    logic       mouse_tog_q;
    logic [8:0] mouse_dx_q;
    logic [1:0] sens_q;
    logic       enable_q;
    logic       input_valid_q;

    // Event tracking and state.
    logic       input_ready;
    logic [1:0] spin_seen;
    logic [7:0] pad_seen [0:1];
    logic [1:0] pad_primed;
    logic       mouse_seen;
    logic [5:0] spin_hold [0:1];
    logic signed [17:0] pending [0:1];
    logic [11:0] dial_acc [0:1];

    wire frame_tick = vblank_q && !vblank_q2;

    logic               spin_ev    [0:1];
    logic               pad_ev     [0:1];
    logic               mouse_ev;
    logic signed [11:0] spin_term  [0:1];
    logic signed [11:0] pad_term   [0:1];
    logic signed [11:0] mouse_term;
    logic signed [11:0] half_px    [0:1];
    logic signed [17:0] ev_q4      [0:1];
    logic signed [17:0] sat        [0:1];
    logic               go_right   [0:1];
    logic               go_left    [0:1];
    logic signed [17:0] pending_nx [0:1];

    always_comb begin
        mouse_ev   = input_ready && (mouse_tog_q != mouse_seen);
        mouse_term = mouse_ev ? $signed({{3{mouse_dx_q[8]}}, mouse_dx_q}) : 12'sd0;
        for (int c = 0; c < 2; c++) begin
            spin_ev[c]   = input_ready && (spin_q[c][8] != spin_seen[c]);
            pad_ev[c]    = input_ready && (pad_q[c] != pad_seen[c]);
            spin_term[c] = spin_ev[c]
                ? $signed({{3{spin_q[c][7]}}, spin_q[c][7:0], 1'b0}) : 12'sd0;
            // Paddle: absolute to relative, 9-bit signed difference so a
            // full sweep 255 -> 0 is -255, never +1. The first change after
            // reset only primes (a paddle's first report is its absolute
            // position, not a movement).
            pad_term[c]  = (pad_ev[c] && pad_primed[c] && !spin_ev[c] &&
                            (spin_hold[c] == 6'd0))
                ? $signed(({4'd0, pad_q[c]} - {4'd0, pad_seen[c]}) << 1) : 12'sd0;
            half_px[c]   = spin_term[c] + pad_term[c] + ((c == 0) ? mouse_term : 12'sd0);
            ev_q4[c]     = gain_q4(half_px[c], sens_q);
            sat[c]       = saturate(pending[c] + ev_q4[c]);
            go_right[c]  = frame_tick && (sat[c] >= STEP_Q4);
            go_left[c]   = frame_tick && (sat[c] <= -STEP_Q4);
            pending_nx[c] = go_right[c] ? (sat[c] - STEP_Q4) :
                            go_left[c]  ? (sat[c] + STEP_Q4) : sat[c];
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            vblank_q      <= 1'b0;
            vblank_q2     <= 1'b0;
            spin_q[0]     <= 9'd0;
            spin_q[1]     <= 9'd0;
            pad_q[0]      <= 8'd0;
            pad_q[1]      <= 8'd0;
            mouse_tog_q   <= 1'b0;
            mouse_dx_q    <= 9'd0;
            sens_q        <= 2'd0;
            enable_q      <= 1'b0;
            input_valid_q <= 1'b0;
        end else begin
            vblank_q      <= vblank;
            vblank_q2     <= vblank_q;
            spin_q[0]     <= spinner_1;
            spin_q[1]     <= spinner_2;
            pad_q[0]      <= paddle_1;
            pad_q[1]      <= paddle_2;
            mouse_tog_q   <= mouse_toggle;
            mouse_dx_q    <= mouse_dx;
            sens_q        <= sensitivity;
            enable_q      <= enable;
            input_valid_q <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            input_ready <= 1'b0;
            spin_seen   <= 2'b00;
            mouse_seen  <= 1'b0;
            pad_primed  <= 2'b00;
            emu_left    <= 2'b00;
            emu_right   <= 2'b00;
            for (int c = 0; c < 2; c++) begin
                pad_seen[c]  <= 8'd0;
                spin_hold[c] <= 6'd0;
                pending[c]   <= 18'sd0;
                dial_acc[c]  <= 12'd0;
            end
        end else begin
            // Track every hps_io value each clock; an event is a change
            // since the previous clock, so each toggle counts exactly once.
            spin_seen  <= {spin_q[1][8], spin_q[0][8]};
            mouse_seen <= mouse_tog_q;
            pad_seen[0] <= pad_q[0];
            pad_seen[1] <= pad_q[1];
            if (!input_ready) begin
                input_ready <= input_valid_q;
            end else begin
                for (int c = 0; c < 2; c++) begin
                    if (pad_ev[c])
                        pad_primed[c] <= 1'b1;
                    if (spin_ev[c])
                        spin_hold[c] <= 6'd63;
                    else if (frame_tick && (spin_hold[c] != 6'd0))
                        spin_hold[c] <= spin_hold[c] - 6'd1;
                    if (!enable_q) begin
                        pending[c]   <= 18'sd0;
                        dial_acc[c]  <= 12'd0;
                        emu_left[c]  <= 1'b0;
                        emu_right[c] <= 1'b0;
                    end else begin
                        pending[c]  <= pending_nx[c];
                        dial_acc[c] <= dial_acc[c] + ev_q4[c][11:0];
                        if (frame_tick) begin
                            emu_right[c] <= go_right[c];
                            emu_left[c]  <= go_left[c];
                        end
                    end
                end
            end
        end
    end

    // PORT_REVERSE'd wrapping position: idle (and reset) reads 0xFF, and
    // clockwise / rightward movement counts down, as MAME's SPIN ports do.
    assign dial_1 = ~dial_acc[0][11:4];
    assign dial_2 = ~dial_acc[1][11:4];

endmodule
