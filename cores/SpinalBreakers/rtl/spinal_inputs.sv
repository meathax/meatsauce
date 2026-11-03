// SPDX-License-Identifier: GPL-3.0-or-later
// Logical active-high controls to MAME 0.289 active-low board inputs.
// Player bits 0..6 are up, down, left, right, button1, button2, button3.
// Physical joystick/HPS mapping and DIP presentation are separate concerns.
module spinal_inputs (
    input logic [6:0] player1,player2,
    input logic coin1,coin2,start1,start2,service_credit,test_switch,
    input logic [15:0] dip_switches,
    output logic [15:0] in0,in1,dips
);
    always_comb begin
        in0=16'hffff;
        in0[6:0]=~player1;
        in0[8]=~coin1;in0[9]=~coin2;
        in0[10]=~start1;in0[11]=~start2;
        in0[14]=~service_credit;
        in1=16'h00ff;
        in1[6:0]=~player2;
        dips=dip_switches;
        dips[13]=dip_switches[13] && !test_switch;
    end
endmodule
