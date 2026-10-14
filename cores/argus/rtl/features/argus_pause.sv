// A frame boundary keeps user/OSD pauses visually coherent. Hiscore borrowing
// requires paused CPU enables for a complete system cycle before grant.
// Parent must quiesce an in-flight CPU bus transaction before forwarding grant.
module argus_pause (
    input logic clk_sys, reset,
    input logic user_pause, osd_open, hiscore_pause, frame_start,
    output logic pause_game, ram_grant
);
    logic visual_pause, paused_previous;
    always_comb begin
        pause_game = visual_pause | hiscore_pause;
        ram_grant = hiscore_pause & pause_game & paused_previous & ~reset;
    end
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            visual_pause <= 0;
            paused_previous <= 0;
        end else begin
            if (frame_start) visual_pause <= user_pause | osd_open;
            paused_previous <= pause_game;
        end
    end
endmodule
