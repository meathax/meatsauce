// SPDX-License-Identifier: GPL-3.0-or-later
// Current Hangzo ROM at 0x2652 copies 70 words from 0x20092 into work RAM.
// Observe completed CPU writes, never host/side-port writes. The final name
// byte changes after a legitimate insertion; readiness is latched per reset.
module hangzo_score_initialization #(
    parameter [23:0] TABLE_FIRST = 24'h3f003a,
    parameter [23:0] TABLE_LAST_WORD = 24'h3f00c4,
    parameter [15:0] FIRST_WORD = 16'h0002,
    parameter [15:0] LAST_WORD = 16'h5920
) (
    input wire clk,reset,cpu_accepted,cpu_write,
    input wire [23:0] cpu_address,
    input wire [1:0] cpu_byte_enable,
    input wire [15:0] cpu_data,
    output reg initialized
);
    reg first_seen;
    always @(posedge clk) begin
        if(reset) begin
            first_seen <= 1'b0;
            initialized <= 1'b0;
        end else if(!initialized && cpu_accepted && cpu_write) begin
            if(cpu_address==TABLE_FIRST && cpu_byte_enable!=0)
                first_seen <= cpu_byte_enable==2'b11 && cpu_data==FIRST_WORD;
            if(cpu_address==TABLE_LAST_WORD && cpu_byte_enable==2'b11 && cpu_data==LAST_WORD && first_seen)
                initialized <= 1'b1;
        end
    end
endmodule
