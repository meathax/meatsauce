// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from the pinned Leland donor's leland_board.sv pixel accumulator.
// RATE_PROFILE 0 is the nominal 57,272,724 Hz diagnostic root; profile 1 is
// the realizable 630 MHz / 11 PLL root. Both keep pixel exactly root / 8.
// Free-running phase, as in the donor: game reset/pause must not restart it.
// These are fabric enables, never clocks or permission for timing exceptions.
`timescale 1ns/1ps
module leland_target_enables #(
    parameter integer RATE_PROFILE = 0
) (
    input wire clk_sys,
    output reg ce_pixel = 1'b0,
    output reg ce_z80 = 1'b0,
    output reg ce_186 = 1'b0,
    output reg ce_4m = 1'b0
);
localparam [31:0] ACCUMULATOR_DENOMINATOR = RATE_PROFILE == 1 ? 32'd315 : 32'd57272724;
localparam [31:0] Z80_INCREMENT = RATE_PROFILE == 1 ? 32'd33 : 32'd6000000;
localparam [31:0] SOUND_INCREMENT = RATE_PROFILE == 1 ? 32'd44 : 32'd8000000;
reg [31:0] z80_phase = 0, sound_phase = 0;
reg [2:0] pixel_count = 0;
reg sound_half = 0;
wire [31:0] z80_next = z80_phase + Z80_INCREMENT;
wire [31:0] sound_next = sound_phase + SOUND_INCREMENT;
always @(posedge clk_sys) begin
    pixel_count <= pixel_count + 1'b1;
    ce_pixel <= pixel_count == 3'd7;
    ce_z80 <= z80_next >= ACCUMULATOR_DENOMINATOR;
    z80_phase <= z80_next >= ACCUMULATOR_DENOMINATOR ? z80_next - ACCUMULATOR_DENOMINATOR : z80_next;
    ce_186 <= sound_next >= ACCUMULATOR_DENOMINATOR;
    sound_phase <= sound_next >= ACCUMULATOR_DENOMINATOR ? sound_next - ACCUMULATOR_DENOMINATOR : sound_next;
    ce_4m <= 1'b0;
    if (sound_next >= ACCUMULATOR_DENOMINATOR) begin
        sound_half <= ~sound_half;
        ce_4m <= sound_half;
    end
end
endmodule
