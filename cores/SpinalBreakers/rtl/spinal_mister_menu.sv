// SPDX-License-Identifier: GPL-3.0-or-later
// Candidate status allocation for the MiSTer-facing game wrapper.
// Direct video cannot use framebuffer rotation or HDMI scaling.
module spinal_mister_menu #(parameter bit CRT_SUPPORTED=0) (
    input wire [127:0] status,
    input wire direct_video,
    output wire user_reset,pause_request,service_in,test_in,hiscore_autosave,
    output wire [2:0] video_effects,
    output wire [1:0] aspect_choice,scale_choice,
    output wire rotation_request,rotation_ccw,
    output wire [15:0] status_menumask
);
    assign user_reset=status[0];
    assign video_effects=(status[2:1]==0) ? 3'd0 : {1'b0,status[2:1]}+3'd1;
    assign rotation_request=!direct_video && (status[4:3]==1 || status[4:3]==2);
    assign rotation_ccw=status[4:3]==2;
    assign scale_choice=direct_video || status[6:5]==3 ? 2'd0 : status[6:5];
    assign hiscore_autosave=!status[7];
    assign pause_request=status[8];
    assign service_in=status[9];
    assign test_in=status[10];
    assign aspect_choice=direct_video ? 2'd0 : status[122:121];
    assign status_menumask={13'd0,!CRT_SUPPORTED,(!CRT_SUPPORTED || !status[54]),direct_video};
endmodule
