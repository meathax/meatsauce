module s32_monitor_audio_route (
    input  signed [15:0] monitor_a,
    input  signed [15:0] monitor_b,
    input                screen_sel,
    input                splitscreen,
    output signed [15:0] audio_l,
    output signed [15:0] audio_r
);

wire signed [15:0] active_audio = screen_sel ? monitor_b : monitor_a;

assign audio_l = splitscreen ? monitor_a : active_audio;
assign audio_r = splitscreen ? monitor_b : active_audio;

endmodule
