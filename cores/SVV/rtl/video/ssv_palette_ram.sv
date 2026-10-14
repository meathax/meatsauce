// SPDX-License-Identifier: GPL-3.0-or-later
// 32768-entry xRGB888 palette on a 16-bit CPU bus.
`timescale 1ns/1ps

module ssv_palette_ram (
    input  logic        clk,
    input  logic [15:0] cpu_addr,
    input  logic [15:0] cpu_data,
    input  logic  [1:0] cpu_be,
    input  logic        cpu_we,
    output logic [15:0] cpu_q,

    input  logic [14:0] video_index,
    output logic [23:0] video_rgb,
    // MAME clears the indexed bitmap to pen 0 before checking video-enable.
    // Expose that same pen for software-blanked active pixels.
    output logic [23:0] background_rgb
);

// The odd word of an SSV palette entry is 00RR: eight bits of red and eight
// bits SSV never defines. Only the red byte reaches the screen, so only the red
// byte is stored -- that halves the odd bank from 64 M10K to 32, about 6% of
// the device, on a part where block RAM (530 of 553) is the binding constraint
// and logic is not.
//
// The trade: a CPU read of the odd word returns zero in the undefined byte
// rather than the value last written. Measured over 250 gameplay frames, Dyna
// Gear performs 94,008 palette writes and *zero* palette reads, so nothing
// observes it. If a future title reads palette RAM back, widen this bank again
// -- the cost is exactly those 32 blocks.
logic cpu_bank_d;
wire [14:0] bank_addr = cpu_addr[15:1];
wire [15:0] even_cpu_q;
wire  [7:0] odd_cpu_q;
wire [15:0] even_video_q;
wire  [7:0] odd_video_q;
logic [15:0] background_even_q;
logic  [7:0] background_odd_q;

always_ff @(posedge clk)
    cpu_bank_d <= cpu_addr[0];

// Keep a tiny mirror of palette entry zero.  The RAM's video port is already
// consumed by the live scanline index, while MAME's bitmap clear needs pen 0
// concurrently when video is disabled.
always_ff @(posedge clk) begin
    if (cpu_we && (cpu_addr == 16'd0)) begin
        if (cpu_be[0]) background_even_q[7:0]  <= cpu_data[7:0];
        if (cpu_be[1]) background_even_q[15:8] <= cpu_data[15:8];
    end
    if (cpu_we && (cpu_addr == 16'd1) && cpu_be[0])
        background_odd_q <= cpu_data[7:0];
end

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) even_words (
    .clock_a(clk), .address_a(bank_addr), .data_a(cpu_data),
    .byteena_a(cpu_be), .wren_a(cpu_we && !cpu_addr[0]), .q_a(even_cpu_q),
    .clock_b(clk), .address_b(video_index), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(even_video_q)
);

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768), .DATA_WIDTH(8)) odd_words (
    .clock_a(clk), .address_a(bank_addr), .data_a(cpu_data[7:0]),
    .byteena_a(cpu_be[0]), .wren_a(cpu_we && cpu_addr[0]), .q_a(odd_cpu_q),
    .clock_b(clk), .address_b(video_index), .data_b(8'd0),
    .byteena_b(1'b0), .wren_b(1'b0), .q_b(odd_video_q)
);

always_comb begin
    // The undefined upper byte of an odd word reads back as zero; see the note
    // above for why that is acceptable and what it buys.
    cpu_q = cpu_bank_d ? {8'd0, odd_cpu_q} : even_cpu_q;
    // Raw 32-bit entry is 00RRGGBB: even word GGBB, odd word 00RR.
    video_rgb = {odd_video_q, even_video_q[15:8], even_video_q[7:0]};
    background_rgb = {background_odd_q,
                      background_even_q[15:8], background_even_q[7:0]};
end

endmodule
