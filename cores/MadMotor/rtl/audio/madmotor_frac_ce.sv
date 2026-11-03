// SPDX-License-Identifier: GPL-3.0-or-later
module madmotor_frac_ce #(
    parameter logic [31:0] NUM=1,
    parameter logic [31:0] DEN=2
)(input logic clk, reset, output logic ce);
    logic [31:0] phase;
    wire [32:0] next_phase={1'b0,phase}+{1'b0,NUM};
    always_ff @(posedge clk) begin
        if(reset) begin phase<=0;ce<=0;end
        else if(next_phase>={1'b0,DEN}) begin phase<=next_phase-DEN;ce<=1;end
        else begin phase<=next_phase[31:0];ce<=0;end
    end
endmodule
