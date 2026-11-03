// SPDX-License-Identifier: GPL-3.0-or-later
// Extends the donor's set-before-ACK IRQ latch with virtual ACK ownership.
// Root-edge timestamps, not clock enables or unconstrained clock domains.
`timescale 1ns/1ps
module leland_irq_source(
    input wire clk,
    input wire reset,
    input wire set_irq,
    input wire acknowledge,
    input wire [63:0] ack_clock,
    output reg irq_n=1'b1,
    output reg [63:0] root_clock=0,
    output reg [64:0] event_clock=0
);
always @(posedge clk) begin
    if(reset)begin root_clock<=0;event_clock<=0;irq_n<=1;end
    else begin
        root_clock<=root_clock+1'b1;
        if(set_irq)begin
            // The extra bit preserves the donor's set priority on an ACK edge.
            event_clock<={root_clock,1'b1};
            irq_n<=0;
        end else if(acknowledge && event_clock <= {ack_clock,1'b0})irq_n<=1;
    end
end
endmodule

module leland_irq_input_filter(
    input wire clk,
    input wire reset,
    input wire cpu_ce,
    input wire acknowledge,
    input wire [63:0] sampled_clock,
    input wire [64:0] event_clock,
    input wire sampled_irq_n,
    output wire irq_cpu_n
);
reg ack_valid=0;
reg [63:0] last_ack_clock=0;
assign irq_cpu_n = sampled_irq_n || (ack_valid && event_clock <= {last_ack_clock,1'b0});
always @(posedge clk) begin
    if(reset)begin ack_valid<=0;last_ack_clock<=0;end
    else if(cpu_ce && acknowledge)begin ack_valid<=1;last_ack_clock<=sampled_clock;end
end
endmodule
