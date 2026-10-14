// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps a regular native 455x262 / 320x240 raster (one pixel enable per 12
// clocks, game CRTC sync geometry) running while the game board is held in
// reset or loading, so direct video and the scaler never lose sync. When the
// game is active its registered raster is passed through; the hand-off occurs
// on a fallback pixel boundary. All outputs are registered (one clock).
module cs_video_hold #(
    parameter HTOT = 455, VTOT = 262, HVIS = 320, VVIS = 240,
    parameter HSYNC_BEGIN = 344, HSYNC_END = 378, VSYNC_BEGIN = 244, VSYNC_END = 247,
    parameter PERIOD = 12
) (
    input  logic clk, game_active,
    input  logic game_ce, game_hblank, game_vblank, game_hs, game_vs,
    input  logic [11:0] game_x, game_y,
    input  logic [23:0] game_rgb,
    output logic ce, hblank, vblank, hs, vs,
    output logic [11:0] x, y,
    output logic [23:0] rgb
);
    logic [5:0] div = 0;
    logic [11:0] fx = 0, fy = 0;
    logic use_game = 0;
    wire tick = div == 6'(PERIOD-1);
    always_ff @(posedge clk) begin
        div <= tick ? 6'd0 : div + 6'd1;
        if (tick) begin
            use_game <= game_active;
            if (fx == 12'(HTOT-1)) begin
                fx <= 0;
                fy <= fy == 12'(VTOT-1) ? 12'd0 : fy + 12'd1;
            end else fx <= fx + 12'd1;
        end
        if (use_game) begin
            ce <= game_ce; hblank <= game_hblank; vblank <= game_vblank;
            hs <= game_hs; vs <= game_vs; x <= game_x; y <= game_y; rgb <= game_rgb;
        end else begin
            ce <= tick; hblank <= fx >= 12'(HVIS); vblank <= fy >= 12'(VVIS);
            hs <= !(fx >= 12'(HSYNC_BEGIN) && fx < 12'(HSYNC_END));
            vs <= !(fy >= 12'(VSYNC_BEGIN) && fy < 12'(VSYNC_END));
            x <= fx; y <= fy; rgb <= 24'd0;
        end
    end
endmodule
