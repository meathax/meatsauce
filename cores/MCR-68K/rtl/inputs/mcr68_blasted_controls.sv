`timescale 1ns/1ps

module mcr68_blasted_controls (
    input  logic        osd_tilt,
    input  logic [8:5]  joystick_0,
    input  logic [8:5]  joystick_1,
    input  logic [8:7]  joystick_2,
    output logic [2:0]  coin,
    output logic        tilt,
    output logic        service_credit
);

always_comb begin
    // The cabinet's numbered coin lines are opposite its numbered control
    // bundles: COIN2 joins the P1-control station and COIN1 joins P2.
    coin[0]        = joystick_1[5] | joystick_1[6];
    coin[1]        = joystick_0[5] | joystick_0[6];
    coin[2]        = 1'b0;
    tilt           = osd_tilt | joystick_0[7] | joystick_1[7] | joystick_2[7];
    service_credit = joystick_0[8] | joystick_1[8] | joystick_2[8];
end

endmodule
