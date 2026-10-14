// SPDX-License-Identifier: GPL-3.0-or-later
// Target raw port layout: MAME 0.289 zeroteam; see docs/INPUTS.md.
module ZeroTeam_inputs (
    input wire [15:0] joy0,joy1,joy2,joy3,
    input wire [15:0] system_config,
    input wire service_credit,service_test,
    output wire [7:0] p1,p2,p3,p4,coin,
    output wire [15:0] system_port
);
    function automatic [7:0] player(input [15:0] joy);
        // Two-button cabinet: Attack and Jump only (bit 6 stays high, as on the PCB).
        player={2'b11,~joy[5],~joy[4],~joy[0],~joy[1],~joy[2],~joy[3]};
    endfunction
    assign p1=player(joy0),p2=player(joy1),p3=player(joy2),p4=player(joy3);
    assign coin={4'hf,~joy3[11],~joy2[11],~joy1[11],~joy0[11]};
    // Cabinet selection and service-mode DIP occupy SYSTEM, not DSW.
    assign system_port={system_config[15:12],system_config[11]&~service_test,system_config[10:8],
        2'b11,~joy3[10],~joy2[10],~service_credit,1'b1,~joy1[10],~joy0[10]};
endmodule

module ZeroTeam_keyboard (
    input wire clk,reset,
    input wire [10:0] ps2_key,
    output reg [15:0] joy0,joy1,joy2,joy3
);
    reg previous_toggle;
    always @(posedge clk) begin
        if(reset) begin
            previous_toggle<=ps2_key[10];
            joy0<=0;joy1<=0;joy2<=0;joy3<=0;
        end else if(previous_toggle!=ps2_key[10]) begin
            previous_toggle<=ps2_key[10];
            case(ps2_key[8:0])
                // P1: arrows / left Ctrl / left Alt.
                9'h175: joy0[3]<=ps2_key[9];
                9'h172: joy0[2]<=ps2_key[9];
                9'h16b: joy0[1]<=ps2_key[9];
                9'h174: joy0[0]<=ps2_key[9];
                9'h014: joy0[4]<=ps2_key[9];
                9'h011: joy0[5]<=ps2_key[9];
                // P2: I/K/J/L / Z/X.
                9'h043: joy1[3]<=ps2_key[9];
                9'h042: joy1[2]<=ps2_key[9];
                9'h03b: joy1[1]<=ps2_key[9];
                9'h04b: joy1[0]<=ps2_key[9];
                9'h01a: joy1[4]<=ps2_key[9];
                9'h022: joy1[5]<=ps2_key[9];
                // P3: T/G/F/H / B/N.
                9'h02c: joy2[3]<=ps2_key[9];
                9'h034: joy2[2]<=ps2_key[9];
                9'h02b: joy2[1]<=ps2_key[9];
                9'h033: joy2[0]<=ps2_key[9];
                9'h032: joy2[4]<=ps2_key[9];
                9'h031: joy2[5]<=ps2_key[9];
                // P4: keypad 8/5/4/6 / 1/2 (nonextended codes).
                9'h075: joy3[3]<=ps2_key[9];
                9'h073: joy3[2]<=ps2_key[9];
                9'h06b: joy3[1]<=ps2_key[9];
                9'h074: joy3[0]<=ps2_key[9];
                9'h069: joy3[4]<=ps2_key[9];
                9'h072: joy3[5]<=ps2_key[9];
                // Top row 1..4 = starts, 5..8 = respective coin switches.
                9'h016: joy0[10]<=ps2_key[9];
                9'h01e: joy1[10]<=ps2_key[9];
                9'h026: joy2[10]<=ps2_key[9];
                9'h025: joy3[10]<=ps2_key[9];
                9'h02e: joy0[11]<=ps2_key[9];
                9'h036: joy1[11]<=ps2_key[9];
                9'h03d: joy2[11]<=ps2_key[9];
                9'h03e: joy3[11]<=ps2_key[9];
                9'h04d: joy0[12]<=ps2_key[9]; // P: pause edge.
                9'h006: joy0[13]<=ps2_key[9]; // F2: service credit.
                9'h004: joy0[14]<=ps2_key[9]; // F3: service-mode switch.
                default: ;
            endcase
        end
    end
endmodule
