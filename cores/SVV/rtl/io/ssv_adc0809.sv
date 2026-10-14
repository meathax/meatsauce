// SPDX-License-Identifier: GPL-3.0-or-later
// ADC0809 bus-level model for the GDFS daughterboard.  The pinned MAME 0.289
// driver supplies a 1 MHz clock but marks that clock unknown.  Consequently
// conversion_cycles is a descriptor-selected deterministic profile value,
// not a claim about PCB conversion time.
`timescale 1ns/1ps
module ssv_adc0809 (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] conversion_cycles,
    input  logic [2:0] channel,
    input  logic       start,
    input  logic [7:0] ch0, ch1, ch2, ch3,
    output logic [7:0] data,
    output logic       eoc_pulse,
    output logic       busy
);
logic start_d;
logic [7:0] count;
logic [7:0] sampled;
always_comb begin
    case (channel)
        3'd0: sampled = ch0;
        3'd1: sampled = ch1;
        3'd2: sampled = ch2;
        3'd3: sampled = ch3;
        default: sampled = 8'hff;
    endcase
end
always_ff @(posedge clk) begin
    if (rst) begin
        start_d <= 1'b0; count <= 8'd0; data <= 8'h00;
        eoc_pulse <= 1'b0; busy <= 1'b0;
    end else begin
        start_d <= start;
        eoc_pulse <= 1'b0;
        if (start && !start_d) begin
            count <= conversion_cycles;
            busy <= 1'b1;
        end else if (busy) begin
            if (count <= 8'd1) begin
                data <= sampled;
                busy <= 1'b0;
                eoc_pulse <= 1'b1;
            end else count <= count - 1'd1;
        end
    end
end
endmodule
