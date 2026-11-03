// SPDX-License-Identifier: GPL-3.0-or-later
// Apply DIP-backed service transitions through the game reset path only.
module darkmist_service_reset (
    input wire clk,power_reset,run_ready,downloading,service_n,
    output reg reset_request=0
);
    reg armed=0,previous=1;
    always @(posedge clk) begin
        reset_request<=0;
        if(power_reset || !run_ready || downloading) begin
            armed<=0;previous<=service_n;
        end else begin
            if(armed && service_n!=previous)reset_request<=1;
            armed<=1;previous<=service_n;
        end
    end
endmodule
