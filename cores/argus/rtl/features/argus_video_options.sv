// Parent allocates status bits and loads ROT270 defaults for Argus/Valtric.
// Current Template video_freak SCALE 4 is HV integer; code 2 means HV integer-.
module argus_video_options (
    input logic [1:0] rotation, scale,
    input logic native_flip_180,
    input logic direct_video, forced_scandoubler,
    input logic [2:0] effects,
    input logic crt_enable,
    output logic rotate_ccw, no_rotate, presentation_flip,
    output logic user_flip_180,
    output logic [11:0] arx, ary,
    output logic [2:0] freak_scale,
    output logic crt_active, hdmi_menu_hidden, crt_menu_hidden
);
    always_comb begin
        no_rotate = direct_video || rotation == 0 || rotation == 3;
        rotate_ccw = rotation == 2;
        // V2 renderers combine the user setting with board flip once. HDMI
        // must not apply that same 180-degree transform a second time.
        user_flip_180 = native_flip_180 || rotation == 3;
        presentation_flip = 1'b0;
        arx = no_rotate ? 12'd4 : 12'd3;
        ary = no_rotate ? 12'd3 : 12'd4;
        freak_scale = direct_video ? 3'd0 : ((scale == 1) ? 3'd1 : (scale == 2) ? 3'd4 : 3'd0);
        // Retimed CRT CE is unsuitable for direct video. Preserve upstream
        // forced_scandoubler; bypass this optional native CRT chain instead.
        crt_active = crt_enable && !direct_video && !forced_scandoubler && effects == 0;
        hdmi_menu_hidden = direct_video;
        crt_menu_hidden = !crt_active;
    end
endmodule
