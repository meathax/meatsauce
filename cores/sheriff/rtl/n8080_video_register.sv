// SPDX-License-Identifier: GPL-3.0-or-later
// SN74198 functional register. TI TTL Data Book, second edition, page 7-338.
// ce_clock represents a rising edge of the physical chip clock; deriving it
// and the board's load/direction signals is the caller's responsibility.
module n8080_video_register (
    input wire clk,
    input wire ce_clock,
    input wire clear_n,
    input wire s0,
    input wire s1,
    input wire serial_right,
    input wire serial_left,
    input wire [7:0] parallel_data, // bit 0 = input A, bit 7 = input H
    output reg [7:0] q,            // bit 0 = QA, bit 7 = QH
    output wire qa,
    output wire qh
);
    assign qa = q[0];
    assign qh = q[7];
    always @(posedge clk or negedge clear_n) begin
        if (!clear_n) q <= 8'b0;
        else if (ce_clock) begin
            case ({s1,s0})
                2'b01: q <= {q[6:0],serial_right}; // QA toward QH
                2'b10: q <= {serial_left,q[7:1]};  // QH toward QA
                2'b11: q <= parallel_data;
                default: ;
            endcase
        end
    end
endmodule
