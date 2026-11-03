// SPDX-License-Identifier: GPL-3.0-or-later
// Credit/gap arithmetic adapted from raiden2_ce_gen.sv, rmonic79 (GPLv3+).
// Exact donor identity is staged under donors/zero-ce-reference/.
// Nominal demand is separate from CPU-side artificial ROM wait classification.
// No clock/phase/SDC transfer: this output is a full-fabric-rate enable.
`timescale 1ns/1ps
module leland_cpu_recovery #(
    parameter integer MIN_GAP=4,
    parameter integer CREDIT_WIDTH=16
)(
    input wire clk,
    input wire reset,
    input wire pause,
    input wire nominal_ce,
    input wire artificial_wait,
    output wire cpu_ce,
    output reg [CREDIT_WIDTH-1:0] pending=0,
    output reg overflow=0
);
localparam integer GW=(MIN_GAP<2)?1:$clog2(MIN_GAP);
reg [GW-1:0] gap=GW'(MIN_GAP-1);
wire earn=nominal_ce && !pause && !reset;
assign cpu_ce=!reset && !pause && !artificial_wait && !overflow &&
              gap>=GW'(MIN_GAP-1) && ((pending!=0) || earn);
// Preserve cooldown through reset/pause, avoiding a shortened restart interval.
always @(posedge clk) begin
    if(cpu_ce)gap<=0;
    else if(gap<GW'(MIN_GAP-1))gap<=gap+1'b1;
    if(reset)begin pending<=0;overflow<=0;end
    else begin
        case({earn,cpu_ce})
            2'b10:begin
                if(&pending)overflow<=1'b1;
                else pending<=pending+1'b1;
            end
            2'b01:pending<=pending-1'b1;
            default:;
        endcase
    end
end
endmodule
