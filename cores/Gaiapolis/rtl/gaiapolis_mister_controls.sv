// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer sends each stick axis as a signed byte centered at zero. The core
// turns the left stick into steady 8-way directions itself instead of using
// JTFRAME's per-axis PWM, which pulses directions and reads as repeated taps.
// A 30% (38/128) radial deadzone engages the stick; it releases below 34/128.
// A secondary axis joins above tan 30 deg of the main axis and leaves below
// tan 25 deg, so cardinals dominate and boundaries do not chatter. While the
// stick is engaged its directions replace the raw D-pad bits.
module gaiapolis_mister_left_stick (
    input  wire        clk,
    input  wire [15:0] stick,
    input  wire [15:0] raw,
    output wire [15:0] joy
);
    wire signed [8:0] x = {stick[7], stick[7:0]};
    wire signed [8:0] y = {stick[15], stick[15:8]};
    wire [8:0] ax = x[8] ? 9'(-x) : x;
    wire [8:0] ay = y[8] ? 9'(-y) : y;
    wire [18:0] radius_sq = 19'(ax*ax) + 19'(ay*ay);
    wire [18:0] ax_k = 19'(ax*10'd1000), ay_k = 19'(ay*10'd1000);
    wire [18:0] ax_on = 19'(ax*10'd577), ax_off = 19'(ax*10'd466);
    wire [18:0] ay_on = 19'(ay*10'd577), ay_off = 19'(ay*10'd466);
    reg engaged = 0, x_act = 0, y_act = 0;
    reg [3:0] dirs = 0;
    wire eng_next = engaged ? radius_sq >= 19'd1156 : radius_sq > 19'd1444;
    wire x_next = x_act ? ax_k >= ay_off : ax_k > ay_on;
    wire y_next = y_act ? ay_k >= ax_off : ay_k > ax_on;
    always @(posedge clk) begin
        engaged <= eng_next;
        x_act <= eng_next && x_next;
        y_act <= eng_next && y_next;
        dirs <= !eng_next ? 4'd0 :
            {y_next && y[8], y_next && !y[8], x_next && x[8], x_next && !x[8]};
    end
    // Bits: 0 right, 1 left, 2 down, 3 up (JTFRAME order, before rotation).
    assign joy = engaged ? {raw[15:4], dirs} : raw;
endmodule

// Presentation composes the PCB's ROT90 mounting with relative user rotation.
// The game applies its cabinet flip before presentation. Keep that native
// transform in every output rather than cancelling it with another half turn.
module gaiapolis_mister_orientation (
    input  wire       direct_video,
    input  wire       portrait,
    input  wire [1:0] user_rotation,
    output wire       rotate_ccw,
    output wire       no_rotate,
    output wire       framebuffer_flip,
    output wire       relative_quarter
);
    reg [1:0] relative_rotation;
    always @* begin
        case (user_rotation)
            2'd0: relative_rotation = 2'd0; // Original
            2'd1: relative_rotation = 2'd1; // Clockwise
            2'd2: relative_rotation = 2'd3; // Counterclockwise
            2'd3: relative_rotation = 2'd2; // Upside down
        endcase
    end
    wire [1:0] rotation = direct_video ? 2'd0 :
        (portrait ? 2'd1 : 2'd0) + relative_rotation;
    assign rotate_ccw       = rotation == 2'd3;
    assign no_rotate        = ~rotation[0];
    assign framebuffer_flip = rotation == 2'd2;
    // JTFRAME already supplies the native portrait aspect ratio. Only a
    // relative quarter turn swaps that ratio in video_freak.
    assign relative_quarter = !direct_video && user_rotation[0] != user_rotation[1];
endmodule

// The PCB sound switch is active high for monaural (MAME dadandrn IN1 bit 4).
// MiSTer's official audio_out mix=3 averages the two routed speakers.
module gaiapolis_mister_audio_mix (
    input  wire       sound_mono,
    output wire [1:0] audio_mix
);
    assign audio_mix = sound_mono ? 2'd3 : 2'd0;
endmodule

// Presentation and storage status; legacy video-adjustment bits are unused.
module gaiapolis_mister_status (
    input wire [63:0] status,
    output wire crop_en,
    output wire [3:0] vcopt,
    output wire [2:0] crop_scale,
    output wire [1:0] ram_save,
    output wire ram_load, gun_border_en, uart_en
);
    wire unused_status = &{status[63:49], status[40:39], status[37:23],
                           status[19:9], status[7:0]};
    assign crop_en = status[41];
    assign vcopt = status[45:42];
    // Menu order puts the nearest HV integer mode before the two explicit
    // narrow/wide modes used by video_freak.
    assign crop_scale = status[48:46] == 3'd2 ? 3'd4 :
                        status[48:46] == 3'd3 ? 3'd2 :
                        status[48:46] == 3'd4 ? 3'd3 :
                        status[48:46] <= 3'd1 ? status[48:46] : 3'd0;
    assign ram_save = status[21:20];
    assign ram_load = status[22];
    assign gun_border_en = status[8];
    assign uart_en = status[38];
endmodule
