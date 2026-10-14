// SPDX-License-Identifier: GPL-3.0-or-later
// Related-Bandido 4J/4G functional horizontal reload and blanking network.
// 4I is the separate free-running low nibble. 4J RCO drives inverted LOAD
// and (through three LS04 stages/C5) the positive 4G clock on its falling edge.
// A/B=0, C/D=4G Qbar6; 4G D2=Qbar6. C5/gate delays are not emulated here.
// Reset is a reproducible digital origin, not physical PCB reset evidence.
module n8080_horizontal_counter (
    input wire clk,
    input wire reset,
    input wire ce_counter,
    input wire [3:0] phase_4i,
    output reg [3:0] upper_4j,
    output reg h_active,
    output wire hb,
    output wire terminal_carry
);
    assign hb=!h_active; // 4G Q5 / TP4; Qbar6 is active high.
    assign terminal_carry=(&upper_4j)&&(&phase_4i);
    always @(posedge clk) begin
        if(reset) begin upper_4j<=12; h_active<=0; end
        else if(ce_counter) begin
            if(terminal_carry) begin
                // 4J captures old Qbar before downstream 4G toggles.
                upper_4j<=h_active ? 4'd12 : 4'd0;
                h_active<=!h_active;
            end else if(&phase_4i) upper_4j<=upper_4j+1'b1;
        end
    end
endmodule
