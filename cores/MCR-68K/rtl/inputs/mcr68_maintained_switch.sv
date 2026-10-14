`timescale 1ns/1ps

module mcr68_maintained_switch (
    input  logic clk,
    input  logic rst,
    input  logic active,
    input  logic push,
    input  logic force_on,
    output logic level
);

logic push_d;
logic latched;

always_ff @(posedge clk) begin
    if (rst || !active) begin
        push_d  <= 1'b0;
        latched <= 1'b0;
    end else begin
        push_d <= push;
        if (force_on)
            latched <= 1'b0;
        else if (push && !push_d)
            latched <= ~latched;
    end
end

always_comb level = force_on | latched;

endmodule
