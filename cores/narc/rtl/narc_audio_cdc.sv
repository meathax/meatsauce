// Latest-sample stereo mailbox from the sound-board clock to MiSTer's audio
// clock. The source holds both channels before toggling one token; the audio
// domain synchronizes the token, then captures the already-stable pair.
`timescale 1ns/1ps
`default_nettype none
module narc_audio_cdc (
    input  wire               clk_sys,
    input  wire               clk_audio,
    input  wire               reset,
    input  wire signed [15:0] audio_l_in,
    input  wire signed [15:0] audio_r_in,
    output reg  signed [15:0] audio_l_out,
    output reg  signed [15:0] audio_r_out
);
    reg signed [15:0] audio_l_hold, audio_r_hold;
    reg               audio_toggle;
    always @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            audio_l_hold <= 16'sd0;
            audio_r_hold <= 16'sd0;
            audio_toggle <= 1'b0;
        end else if (audio_l_in != audio_l_hold ||
                     audio_r_in != audio_r_hold) begin
            audio_l_hold <= audio_l_in;
            audio_r_hold <= audio_r_in;
            audio_toggle <= ~audio_toggle;
        end
    end

    reg signed [15:0] audio_l_cdc1, audio_l_cdc2;
    reg signed [15:0] audio_r_cdc1, audio_r_cdc2;
    reg               audio_toggle_meta, audio_toggle_q, audio_toggle_seen;
    always @(posedge clk_audio or posedge reset) begin
        if (reset) begin
            audio_l_cdc1 <= 16'sd0;
            audio_l_cdc2 <= 16'sd0;
            audio_r_cdc1 <= 16'sd0;
            audio_r_cdc2 <= 16'sd0;
            audio_toggle_meta <= 1'b0;
            audio_toggle_q <= 1'b0;
            audio_toggle_seen <= 1'b0;
        end else begin
            audio_toggle_meta <= audio_toggle;
            audio_toggle_q <= audio_toggle_meta;
            if (audio_toggle_q != audio_toggle_seen) begin
                audio_l_cdc1 <= audio_l_hold;
                audio_r_cdc1 <= audio_r_hold;
                audio_toggle_seen <= audio_toggle_q;
            end
            audio_l_cdc2 <= audio_l_cdc1;
            audio_r_cdc2 <= audio_r_cdc1;
        end
    end

    always @* begin
        audio_l_out = audio_l_cdc2;
        audio_r_out = audio_r_cdc2;
    end
endmodule
`default_nettype wire
