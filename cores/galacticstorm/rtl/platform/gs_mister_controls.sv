// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer controls to the pinned Galastrm unsigned ADC/input ports.
// The flight stick is the left analog stick; the D-pad drives the same axes
// digitally at full deflection only while that analog axis is centred, so
// Main's left-stick-to-D-pad emulation cannot replace proportional values. ADC Y above 0x80 moves the ship up (measured in
// MAME 0.289). invert_y (OSD default) maps stick DOWN to ship UP; otherwise the
// axis follows MAME's PORT_REVERSE convention (stick down, ship down).
// sensitivity: 0 medium (1x), 1 low (1/2x), 2 fast (3/2x, saturating).
module gs_mister_controls (
    input wire [31:0] joystick,joystick2,
    input wire [15:0] analog_stick,   // {Y,X}, signed -127..+127, down/right positive
    input wire invert_y,
    input wire [1:0] sensitivity,
    output wire [7:0] in0,in2,stick_x,stick_y
);
    assign in0={7'b1111111,!joystick[8]};
    assign in2={~joystick[7:4],!joystick2[9],!joystick[9],!joystick[10],!joystick[11]};
    function automatic [7:0] adc(input signed [7:0] value,input [1:0] scale);
        reg signed [9:0] scaled;
        begin
            case(scale)
                2'd1: scaled=$signed({{2{value[7]}},value})>>>1;
                2'd2: scaled=$signed({{2{value[7]}},value})+($signed({{2{value[7]}},value})>>>1);
                default: scaled=$signed({{2{value[7]}},value});
            endcase
            if(scaled>10'sd127) scaled=10'sd127;
            if(scaled<-10'sd127) scaled=-10'sd127;
            adc=8'h80+scaled[7:0];
        end
    endfunction
    wire signed [7:0] raw_x=analog_stick[7:0];
    wire signed [7:0] raw_y=analog_stick[15:8];
    // -128 is not a legal deflection; treat it as -127 so negation cannot wrap.
    wire signed [7:0] safe_y=raw_y==-8'sd128 ? -8'sd127 : raw_y;
    wire signed [7:0] ship_up=invert_y ? safe_y : -safe_y;
    // |axis| <= 15 counts as centred.
    wire x_centred=raw_x[7:4]==4'h0 || raw_x[7:4]==4'hf && raw_x[3:0]!=4'h0;
    wire y_centred=raw_y[7:4]==4'h0 || raw_y[7:4]==4'hf && raw_y[3:0]!=4'h0;
    assign stick_x=x_centred && joystick[1] ? 8'h20 : x_centred && joystick[0] ? 8'he0 : adc(raw_x,sensitivity);
    assign stick_y=y_centred && joystick[3] ? 8'he0 : y_centred && joystick[2] ? 8'h20 : adc(ship_up,sensitivity);
endmodule
