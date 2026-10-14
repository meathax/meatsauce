// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer configures video before downloading the arcade ROM stream. Keep
// sync and pixel enables alive while the game is held at its cold-start state.
//
// While the game raster runs, the standby raster follows its presented pixel
// (position and six-clock phase), so a core reset hands the display over to it
// with no break in line length, frame length or sync.
//
// The game raster restarts at x=0,line=248 when its reset is released.
// release_point marks the one clock on which releasing the reset makes the
// game's first presented pixel (x0/line248, GAME_DELAY clocks after its raster
// CE) land exactly where the standby raster would present it. The output stays
// on the standby raster until the game presents that first pixel, so the
// release is also seamless: no short frame, so the scaler's measured DE line
// count never changes and Main_MiSTer does not re-run its HDMI mode set.
// The timing formulas below mirror osman_raster exactly; the sim/boot_video
// benches compare them clock for clock.
module osman_boot_video #(
    // osman_video presents a raster CE two clocks later (index, then output).
    parameter integer GAME_DELAY = 2
)(
    input wire clk, reset, boot,
    input wire game_ce, game_de, game_hs, game_vs,
    input wire [8:0] game_x,
    input wire [7:0] game_y, game_r, game_g, game_b,
    output wire ce, de, hs, vs,
    output wire [8:0] x,
    output wire [7:0] y, r, g, b,
    output reg release_point
);
    localparam integer PIXEL_DIV = 6, HTOTAL = 512, VTOTAL = 274;
    reg [2:0] divider;
    reg [8:0] boot_x, boot_line;
    wire [7:0] boot_y = boot_line > 9'd255 ? 8'd255 : boot_line[7:0];
    wire boot_ce = !reset && divider == 3'(PIXEL_DIV-1);
    wire boot_de = boot_x < 320 && boot_line >= 8 && boot_line < 248;
    wire boot_hs = !(boot_x >= 384 && boot_x < 416); // same as osman_raster
    wire boot_vs = !(boot_line >= 250 && boot_line < 253);
    wire follow = !boot && game_ce;
    // Released on clock r, the game raster presents x0/line248 on clock
    // r+(PIXEL_DIV-1)+GAME_DELAY. The standby raster presents it PIXEL_DIV
    // clocks after its x511/line247 CE, so clock r must see divider
    // PIXEL_DIV-GAME_DELAY at x511/line247; registered, decode one earlier.
    localparam integer RELEASE_DIV = PIXEL_DIV - GAME_DELAY - 1;
    reg live;
    // game_y saturates at 255 over lines 255..273; boot_line already holds
    // the presented pixel's line there because it follows every game pixel.
    wire game_wrap = game_x == 9'(HTOTAL-1);
    wire [8:0] game_line = game_y != 8'd255 ? {1'b0,game_y} : boot_line;
    wire [8:0] follow_x = game_wrap ? 9'd0 : game_x + 1'b1;
    wire [8:0] follow_line = !game_wrap ? game_line :
                             game_line == 9'(VTOTAL-1) ? 9'd0 : game_line + 1'b1;
    always @(posedge clk) begin
        release_point <= !reset && divider == 3'(RELEASE_DIV) &&
                         boot_x == 9'(HTOTAL-1) && boot_line == 9'd247;
        // Present the game only once it presents a pixel of its own.
        if (reset || boot) live <= 1'b0;
        else if (game_ce) live <= 1'b1;
    end
    always @(posedge clk) begin
        if (reset) begin
            divider <= 0; boot_x <= 0; boot_line <= 248;
        end else if (follow) begin
            // Continue from the pixel after the one the game just presented.
            divider <= 0; boot_x <= follow_x; boot_line <= follow_line;
        end else if (boot_ce) begin
            divider <= 0;
            if (boot_x == 9'(HTOTAL-1)) begin
                boot_x <= 0;
                boot_line <= boot_line == 9'(VTOTAL-1) ? 9'd0 : boot_line + 1'b1;
            end else boot_x <= boot_x + 1'b1;
        end else divider <= divider + 1'b1;
    end
    wire standby = boot || !live;
    assign ce = standby ? boot_ce : game_ce;
    assign de = standby ? boot_de : game_de;
    assign hs = standby ? boot_hs : game_hs;
    assign vs = standby ? boot_vs : game_vs;
    assign x = standby ? boot_x : game_x;
    assign y = standby ? boot_y : game_y;
    assign r = standby ? 8'd0 : game_r;
    assign g = standby ? 8'd0 : game_g;
    assign b = standby ? 8'd0 : game_b;
endmodule
