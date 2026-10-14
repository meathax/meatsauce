// SPDX-License-Identifier: GPL-3.0-or-later
// SPU -> AUDIO_L/R output register. Each 44.19 kHz sample is held stable for its whole
// 1944-clock period.
//
// sys/audio_out.sv crosses AUDIO_L/R into clk_audio (24.576 MHz) by accepting a value only
// when two consecutive clk_audio samples are equal (cl1 == cl2). The former per-clock linear
// ramp changed the output every one or two clk_sys cycles whenever adjacent samples differed
// by more than ~550 LSB, so loud or bright passages never satisfied that check: the framework
// froze on stale values and released them at random instants (heavy distortion). A held
// value passes the check within three clk_audio cycles, after which the framework's own
// high-rate IIR filter and 48 kHz decimation band-limit it, as for every other MiSTer core.
// PERIOD is retained for interface compatibility.
module cs_audio_interp #(parameter integer PERIOD = 1944) (
    input  logic clk, mute,
    input  logic sample_valid,
    input  logic signed [15:0] in_left, in_right,
    output logic signed [15:0] out_left = 0, out_right = 0
);
    always_ff @(posedge clk) begin
        if (mute) begin
            out_left <= 0; out_right <= 0;
        end else if (sample_valid) begin
            out_left <= in_left; out_right <= in_right;
        end
    end
endmodule
