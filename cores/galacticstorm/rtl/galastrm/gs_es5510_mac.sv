// SPDX-License-Identifier: BSD-3-Clause
// Native MAME ES5510 multiply/accumulate behavior (Christian Brunschen).
// Three-clock arithmetic service. Instruction scheduling and destinations
// belong to the execution engine; the accumulator retains overflow bits.
module gs_es5510_mac(
    input wire clk,reset,start,
    output wire ready,
    input wire [23:0] c,d,
    input wire [1:0] shift,
    input wire accumulate,
    input wire signed [63:0] accumulator,
    output reg valid,overflow,
    output reg signed [63:0] result,
    output reg [23:0] value
);
    reg [1:0] phase,saved_shift;
    reg saved_accumulate;
    reg signed [47:0] product48;
    reg signed [63:0] product64,saved_accumulator;
    wire signed [63:0] sum=product64+(saved_accumulate ? saved_accumulator : 64'sd0);
    wire sum_overflow=sum< -64'sh0000800000000000 || sum>=64'sh0000800000000000;
    assign ready=phase==0 && !reset;
    always @(posedge clk) begin
        valid<=0;
        case(phase)
        0: if(start && ready) begin
            product48<=$signed(c)*$signed(d);
            saved_shift<=shift;saved_accumulate<=accumulate;saved_accumulator<=accumulator;
            phase<=1;
        end
        1: begin product64<=$signed({{16{product48[47]}},product48}) <<< saved_shift;phase<=2;end
        2: begin
            result<=sum;overflow<=sum_overflow;
            value<=sum_overflow ? (sum[63] ? 24'h800000 : 24'h7fffff) : sum[47:24];
            valid<=1;phase<=0;
        end
        endcase
        if(reset) begin
            phase<=0;saved_shift<=0;saved_accumulate<=0;product48<=0;
            product64<=0;saved_accumulator<=0;valid<=0;overflow<=0;result<=0;value<=0;
        end
    end
endmodule
