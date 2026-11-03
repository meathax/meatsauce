// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer J1/jn logical joystick convention used by the intended top-level:
// R,L,D,U at bits 0..3, three actions at 4..6, Start at 10 and Coin at 11.
// The matching J1/MRA declarations must preserve the unused action slots.
module spinal_mister_inputs (
    input logic [31:0] joystick_0,joystick_1,
    input logic service_in,test_in,
    output wire [6:0] player1,player2,
    output wire coin1,coin2,start1,start2,service_credit,test_switch,pause_button
);
    assign player1={joystick_0[6:4],joystick_0[0],joystick_0[1],joystick_0[2],joystick_0[3]};
    assign player2={joystick_1[6:4],joystick_1[0],joystick_1[1],joystick_1[2],joystick_1[3]};
    assign start1=joystick_0[10];assign start2=joystick_1[10];
    assign coin1=joystick_0[11];assign coin2=joystick_1[11];
    assign pause_button=joystick_0[12] || joystick_1[12];
    assign service_credit=service_in;assign test_switch=test_in;
endmodule
