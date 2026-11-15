`timescale 1ns/1ps
// Single-port synchronous 8KiB sound RAM candidate. No array reset/init and
// no collision waiver: writes suppress reads, preserving the last read value.
// Join to TV80 only after proving address/data at its CE-qualified T2 edge.
module bigfight_sound_ram (
    input logic clk_sys,
    input logic read_enable,write_enable,
    input logic [12:0] address,
    input logic [7:0] write_data,
    output logic [7:0] read_data
);
    logic [7:0] memory [0:8191];
    always_ff @(posedge clk_sys) begin
        if(write_enable)memory[address]<=write_data;
        else if(read_enable)read_data<=memory[address];
    end
endmodule
