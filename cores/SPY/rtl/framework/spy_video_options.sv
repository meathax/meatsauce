// SPDX-License-Identifier: GPL-3.0-or-later
module spy_video_options (
    input wire [127:0] status,
    input wire direct_video,hs_configured,
    output wire [15:0] menu_mask,
    output wire [127:0] input_status,
    output wire [1:0] rotation,
    output wire [2:0] image_scale
);
    assign menu_mask={11'd0,(direct_video || status[10:8]!=3),!direct_video,
                      !status[32],!hs_configured,direct_video};
    assign rotation = direct_video ? 2'd0 : status[49:48];
    assign image_scale = direct_video ? 3'd0 :
        status[10:8] == 2 ? 3'd4 :
        status[10:8] == 3 ? (status[56] ? 3'd3 : 3'd2) :
        status[10:8] <= 1 ? status[10:8] : 3'd0;
    // Use the game's existing cabinet-flip DIP for native analog/direct video.
    // The program applies it through the same tile and sprite flip registers.
    assign input_status=status ^ ((direct_video && status[57]) ? (128'd1<<52) : 128'd0);
endmodule
