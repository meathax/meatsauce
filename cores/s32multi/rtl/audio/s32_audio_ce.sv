// Exact board-domain audio clock enables for Sega System Multi 32.
// Z80/YM3438 = 32 MHz/4 = 8.0 MHz; MultiPCM = 40 MHz/4 = 10.0 MHz. Derived as
// 32-bit rational NCOs from clk_sys (48.317307 MHz): round(f/clk_sys * 2^32).
module s32_audio_ce(
    input clk,
    input reset,
    input pll_locked,
    output reg ce_z80,
    output reg ce_fm,
    output reg ce_pcm
);
// round(8.0e6 / 48.317307e6 * 2^32) -> 8.000000004 MHz actual
localparam [31:0] Z80_FM_INC = 32'd711126934;
// round(10.0e6 / 48.317307e6 * 2^32) -> 9.999999999 MHz actual
localparam [31:0] PCM_INC    = 32'd888908667;
reg [31:0] acc_z80, acc_pcm;

always @(posedge clk) begin : z80_pcm_nco
    logic [32:0] sum32;
    if (reset) begin
        ce_z80 <= 1'b0; ce_pcm <= 1'b0;
        acc_z80 <= 32'd0; acc_pcm <= 32'd0;
    end else begin
        sum32 = {1'b0, acc_z80} + {1'b0, Z80_FM_INC};
        ce_z80 <= sum32[32]; acc_z80 <= sum32[31:0];
        sum32 = {1'b0, acc_pcm} + {1'b0, PCM_INC};
        ce_pcm <= sum32[32]; acc_pcm <= sum32[31:0];
    end
end

// FM remains free-running through board/ROM reset so JT12's enabled-clock
// reset rings advance. Only PLL loss stops and rephases this independent NCO.
reg [31:0] acc_fm;
always @(posedge clk) begin : fm_nco
    logic [32:0] sum32;
    if (!pll_locked) begin
        ce_fm <= 1'b0; acc_fm <= 32'd0;
    end else begin
        sum32 = {1'b0, acc_fm} + {1'b0, Z80_FM_INC};
        ce_fm <= sum32[32]; acc_fm <= sum32[31:0];
    end
end
endmodule
