// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ns
module hangzo_deco104 (
    input wire clk, reset,
    input wire select, write,
    input wire [13:1] offset,
    input wire [1:0] byte_enable,
    input wire [15:0] write_data,
    input wire [15:0] inputs, system_inputs, dips,
    output reg ready,
    output reg [15:0] read_data,
    output wire [7:0] sound_data,
    output wire sound_write
);
    // The bitswap sends input bits13..11 to output17..15, then masks them
    // away. Input17..14 (feeding chip14..11) are zero in this aperture.
    // Every 2KiB CPU page is therefore the same internal chip page0.
    wire [14:0] mapped = {4'b0, offset[10:1], 1'b0};
    reg [1:0] age;
    reg active;
    wire internal_select = select;
    wire [15:0] chip_data;
    hangzo_deco104_engine #(.USE_MAGIC(0)) u_engine (
        .rst(reset), .clk(clk), .LVBL(1'b1), .cs(internal_select),
        .addr(mapped[13:1]), .din(write_data), .dout(chip_data),
        .rnw(!write), .dsn(~byte_enable),
        .port_a(inputs), .port_b(system_inputs), .port_c(dips),
        .snd_latch(sound_data), .snd_irq(sound_write)
    );
    // Capture the pre-bank-toggle result after the donor's table/RAM pipeline
    // settles, then hold it for the rest of the CPU transfer.
    always @(posedge clk) begin
        if (reset) begin
            age <= 0;
            active <= 0;
            ready <= 0;
            read_data <= 0;
        end else if (!select) begin
            age <= 0;
            active <= 0;
            ready <= 0;
        end else if (!active) begin
            active <= 1;
            age <= 1;
        end else if (!ready) begin
            age <= age + 2'd1;
            if (age == 2'd2) begin
                read_data <= internal_select ? chip_data : 16'd0;
                ready <= 1;
            end
        end
    end
endmodule
