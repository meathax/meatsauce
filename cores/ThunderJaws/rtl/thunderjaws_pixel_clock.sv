// Fixed integer pixel cadence for Atari ThunderJaws.
// Game reset, pause, and ROM download are intentionally ignored here.
module thunderjaws_pixel_clock #(
    parameter integer PIXEL_DIVIDER = 6
) (
    input  logic clk_sys,
    input  logic pll_reset,
    input  logic game_reset,
    input  logic pause,
    input  logic rom_download,
    output logic ce_pixel
);
    localparam integer COUNT_W = $clog2(PIXEL_DIVIDER);
    logic [COUNT_W-1:0] phase;

    always_ff @(posedge clk_sys) begin
        if (pll_reset) begin
            phase    <= '0;
            ce_pixel <= 1'b0;
        end else if (phase == PIXEL_DIVIDER - 1) begin
            phase    <= '0;
            ce_pixel <= 1'b1;
        end else begin
            phase    <= phase + 1'b1;
            ce_pixel <= 1'b0;
        end
    end

    // Prevent unused-input warnings while keeping the reset/pause contract visible.
    logic unused_game_controls;
    always_comb unused_game_controls = game_reset ^ pause ^ rom_download;
endmodule
