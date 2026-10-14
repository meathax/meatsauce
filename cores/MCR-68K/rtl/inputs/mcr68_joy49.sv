// -----------------------------------------------------------------------------
// mcr68_joy49.sv
//
// Williams / Bally-Midway 49-WAY JOYSTICK front end for the MCR-68k core.
// Used by Arch Rivals (`archrivl`, `archrivla`) and Pigskin 621AD (`pigskin`,
// `pigskina`, `pigskinb`). NOT used by the 8-way bootlegs (`archrivlb`,
// `basketbal`) -- see the contrast note at the bottom of this header.
//
// ---------------------------------------------------------------------------
// WHAT THE REAL STICK IS (mcr68.cpp:447-471, verbatim comment in MAME 0.289)
// ---------------------------------------------------------------------------
// The Williams 49-way stick is a 7x7 GRID of leaf switches -- 7 discrete
// positions per axis, 49 (7x7) reachable cells. It is NOT an analog stick and
// NOT a plain 8-way: the game reads a 4-bit code per axis and gets
// three-steps-of-deflection resolution in each direction.
//
// Per-axis wire code, 4 bits, reported ACTIVE HIGH (this is the one place in
// the whole MCR-68k input path that is NOT active low):
//
//     idx  code   meaning                (mcr68.cpp:462-470)
//      0   4'h7   left / up   FULL
//      1   4'h3   left / up   2/3
//      2   4'h1   left / up   1/3
//      3   4'h0   CENTRE
//      4   4'hC   right / down 1/3
//      5   4'hE   right / down 2/3
//      6   4'hF   right / down FULL
//
// MAME's table (mcr68.cpp:473):
//     static const uint8_t translate49[7] = { 0x7,0x3,0x1,0x0,0xc,0xe,0xf };
//
// Note the code is NOT monotonic as an integer and is NOT a thermometer code
// in one direction: the left/up half counts leading 1s from bit0 upward
// (7,3,1) while the right/down half counts leading 1s from bit3 downward
// (C,E,F). Centre is 0. This is exactly what a two-sided leaf-switch ladder
// with a common centre rest position produces, and it is why the game can
// tell "no stick connected" (all-0 = centre) from any deflection.
//
// MAME derives the index from an analog ioport:
//     translate49[ioport("49WAYX1")->read() >> 4]
// with the port declared
//     PORT_BIT(0xff, 0x38, IPT_AD_STICK_X) PORT_MINMAX(0x00,0x6f) ...
// (archrivl: mcr68.cpp:951-961; pigskin: mcr68.cpp:1080-1090).
// So the ioport value is confined to 0x00..0x6F, `>>4` yields 0..6, and the
// declared rest value 0x38 lands in index 3 = centre.
//
// ---------------------------------------------------------------------------
// PER-TITLE AXIS INVERSION -- a real, easily-missed difference
// ---------------------------------------------------------------------------
// pigskin declares PORT_REVERSE on BOTH X axes (mcr68.cpp:1081 "49WAYX1",
// :1087 "49WAYX2") and on NEITHER Y axis. archrivl declares PORT_REVERSE on
// no axis at all (mcr68.cpp:952,955,958,961). Reversing a port whose range is
// exactly 0x00..0x6F maps raw v -> 0x6F-v, and because the seven zones are
// 16 counts wide and the range is exactly 7*16-1, that is EXACTLY index
// i -> 6-i for every i (checked per zone: 0<->6, 1<->5, 2<->4, 3<->3).
// This module therefore implements it as an index mirror, not a value
// subtract, via the `invert_x` / `invert_y` configuration inputs.
//
// ---------------------------------------------------------------------------
// MiSTer PAD -> 49-WAY GRID: the design decision (see doc/rtl_inputs_multigame.md)
// ---------------------------------------------------------------------------
// A MiSTer controller offers a digital d-pad AND (on most pads) a signed 8-bit
// analog stick. The grid needs a 0..6 index per axis. The rule implemented
// here, chosen so that a pad with NO analog stick still works and a pad WITH
// one gets the full seven-step resolution the game was designed around:
//
//   1. Quantise the signed analog axis with the SAME arithmetic MAME's
//      analog-port scaler uses, so the RTL lands in the same zone MAME does
//      for the same physical deflection:
//          raw = 56 + floor(a * 7 / 16)        // a = signed -128..127
//          idx = raw[6:4]                      // raw is provably 0..111
//      a=+127 -> raw=111 -> idx 6 (full).  a=-128 -> raw=0 -> idx 0 (full).
//      a=0    -> raw=56  -> idx 3 (centre).
//      floor() is obtained for free by taking the top bits of the two's
//      complement product -- no divider, one 8x3 multiply per axis.
//   2. A pressed d-pad direction OVERRIDES the analog result with FULL
//      deflection (idx 0 or 6). Both directions pressed at once, or neither,
//      leaves the analog result untouched.
//
// Consequences, stated explicitly because they are the trade-off:
//   * A pad with no analog stick reports a=0 on both axes, which quantises to
//     centre, so rule 2 alone gives a pure 8-way stick that reaches only the
//     FULL positions -- playable, but with none of the 1/3 and 2/3 steps.
//     Arch Rivals and Pigskin use the intermediate steps for run speed, so an
//     analog stick is genuinely better here; this is a hardware property of
//     the cabinet, not something the core can synthesise from a d-pad.
//   * Rule 2 deliberately does NOT try to "ramp" a held d-pad through the
//     intermediate positions over time. A time-dependent input conversion is
//     unverifiable against MAME (it has no equivalent), is frame-rate
//     sensitive, and would silently change behaviour of any future trace diff.
//     Full deflection is the honest, stateless choice.
//   * The resulting analog dead zone (idx 3) is a = -18..+18, i.e. ~14% of
//     full scale, which falls straight out of MAME's own zone arithmetic
//     rather than being an invented constant.
//
// This module is PURELY COMBINATIONAL and holds no state: the whole
// conversion is a function of the current pad sample. Synchronising the raw
// pad bits is the caller's job (see rtl/inputs/mcr68_input_map.sv).
//
// ---------------------------------------------------------------------------
// CONTRAST -- what the 8-way bootleg proves (mcr68.cpp:1926-1940, :988-1005)
// ---------------------------------------------------------------------------
// init_archrivlb installs `archrivlb_port_1_r`, which is literally
// `return ioport("IN1")->read();` -- the raw port, no translate49 at all --
// and archrivlb's IN1 declares plain ACTIVE-LOW 8-way direction bits at
// 15:8 (P1 in 15:12, P2 in 11:8). So on the bootleg the SAME CPU address
// yields a completely different, active-low, 8-bit encoding. That is only
// possible because the bootleg ships patched program ROMs, and it confirms
// that translate49 is a HARDWARE encoding on the real board (the stick's own
// switch matrix), not a software convention the driver invented.
// -----------------------------------------------------------------------------

`default_nettype none

module mcr68_joy49 (
    // Index mirror, per PORT_REVERSE. Static configuration, held stable while
    // the game is out of reset (profile contract rule 2). pigskin drives
    // invert_x=1 / invert_y=0; archrivl drives both 0. Ports rather than
    // parameters so a RUNTIME_GAME_SEL build can switch titles without
    // re-elaborating.
    input  wire              invert_x,
    input  wire              invert_y,

    // Signed analog axis, MiSTer convention: -128 = left/up, +127 = right/down.
    // Tie to 8'sd0 when the pad has no analog stick (that reads as centre).
    input  wire signed [7:0] analog_x,
    input  wire signed [7:0] analog_y,

    // Digital d-pad, ACTIVE HIGH (1 = pressed). Overrides the analog axis
    // with full deflection; both-or-neither leaves the analog value alone.
    input  wire              dpad_up,
    input  wire              dpad_down,
    input  wire              dpad_left,
    input  wire              dpad_right,

    // 0..6 grid index, post-invert. Exposed for observability/regression.
    output logic [2:0]       pos_x,
    output logic [2:0]       pos_y,

    // translate49[] wire codes, ACTIVE HIGH, ready to OR into a port word.
    output logic [3:0]       code_x,
    output logic [3:0]       code_y
);

    // -------------------------------------------------------------------------
    // translate49 -- mcr68.cpp:473. Constant function, synthesises to a 7x4
    // LUT. Index is always in range by construction below, but the default arm
    // returns centre rather than 'x so the function is total.
    // -------------------------------------------------------------------------
    function automatic logic [3:0] translate49(input logic [2:0] idx);
        case (idx)
            3'd0:    translate49 = 4'h7;  // left/up   full
            3'd1:    translate49 = 4'h3;  // left/up   2/3
            3'd2:    translate49 = 4'h1;  // left/up   1/3
            3'd3:    translate49 = 4'h0;  // centre
            3'd4:    translate49 = 4'hC;  // right/down 1/3
            3'd5:    translate49 = 4'hE;  // right/down 2/3
            3'd6:    translate49 = 4'hF;  // right/down full
            default: translate49 = 4'h0;  // unreachable; centre, never 'x
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Analog quantiser: raw = 56 + floor(a*7/16), then idx = raw[6:4].
    //
    // a*7 spans -896..+889, which fits an 11-bit signed value exactly.
    // Taking bits [10:4] of a two's complement product IS floor(product/16)
    // (truncation toward -inf), which is the behaviour we want at the
    // negative end so that a = -1 stays in the centre zone rather than
    // rounding out of it.
    //
    // Sum range: 56 + (-56 .. +55) = 0 .. 111, so the 7-bit result never
    // wraps and raw[6:4] is inherently 0..6 -- no clamp needed, and that is
    // asserted below in simulation rather than assumed.
    // -------------------------------------------------------------------------
    function automatic logic [2:0] quantise(input logic signed [7:0] a);
        // prod[3:0] and raw[8:7]/raw[3:0] are deliberately discarded: the
        // low nibble of `prod` IS the floor-division remainder, and `raw`'s
        // guard bits are provably constant over the 0..111 result range (see
        // the range proof above). Not dead logic -- dropped bits by design.
        /* verilator lint_off UNUSEDSIGNAL */
        logic signed [10:0] prod;
        logic signed [6:0]  q;
        logic signed [8:0]  raw;
        /* verilator lint_on UNUSEDSIGNAL */
        begin
            prod     = $signed(a) * 11'sd7;
            q        = prod[10:4];              // floor(a*7/16), -56..+55
            raw      = 9'sd56 + $signed({{2{q[6]}}, q});
            quantise = raw[6:4];
        end
    endfunction

    logic [2:0] ax_idx, ay_idx;   // analog-only index
    logic [2:0] mx_idx, my_idx;   // after d-pad override
    logic [2:0] fx_idx, fy_idx;   // after PORT_REVERSE mirror

    always_comb begin
        ax_idx = quantise(analog_x);
        ay_idx = quantise(analog_y);

        // D-pad override -> full deflection. Opposite directions pressed
        // simultaneously (mechanically impossible on the real stick, trivially
        // possible on a keyboard) cancel and fall back to the analog value.
        mx_idx = ax_idx;
        if (dpad_left && !dpad_right)      mx_idx = 3'd0;
        else if (dpad_right && !dpad_left) mx_idx = 3'd6;

        my_idx = ay_idx;
        if (dpad_up && !dpad_down)        my_idx = 3'd0;
        else if (dpad_down && !dpad_up)   my_idx = 3'd6;

        // PORT_REVERSE == exact index mirror across the 7 zones (see header).
        fx_idx = invert_x ? (3'd6 - mx_idx) : mx_idx;
        fy_idx = invert_y ? (3'd6 - my_idx) : my_idx;

        pos_x  = fx_idx;
        pos_y  = fy_idx;
        code_x = translate49(fx_idx);
        code_y = translate49(fy_idx);
    end

`ifndef SYNTHESIS
    // The quantiser's 0..6 range claim is load-bearing (no clamp exists).
    // Check it continuously rather than trusting the algebra in the comment.
    always_comb begin
        if (ax_idx > 3'd6)
            $fatal(1, "mcr68_joy49: quantise(X)=%0d out of range for a=%0d", ax_idx, analog_x);
        if (ay_idx > 3'd6)
            $fatal(1, "mcr68_joy49: quantise(Y)=%0d out of range for a=%0d", ay_idx, analog_y);
    end
`endif

endmodule

`default_nettype wire
