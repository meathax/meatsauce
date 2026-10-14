// Exact board-domain audio clock enables. Standard System 32 uses the two
// documented source clocks represented as 32-bit rational NCOs. Multi 32's
// excluded legacy cadence deliberately retains its original 16-bit schedule.
module s32_audio_ce(
    input clk,
    input reset,
    input pll_locked,
    input is_multi32,
    output reg ce_z80,
    output reg ce_fm,
    output reg ce_pcm
);
localparam [31:0] STD_Z80_INC = 32'd715924818;
localparam [31:0] STD_PCM_INC = 32'd1111135834;
reg [31:0] acc_z80, acc_fm, acc_pcm;

always @(posedge clk) begin : z80_pcm_nco
    logic [32:0] sum32;
    logic [16:0] sum16;
    if (reset) begin
        ce_z80 <= 1'b0; ce_pcm <= 1'b0;
        acc_z80 <= 32'd0; acc_pcm <= 32'd0;
    end else if (is_multi32) begin
        sum16 = acc_z80[15:0] + 17'd10851;
        ce_z80 <= sum16[16]; acc_z80 <= {16'd0, sum16[15:0]};
        sum16 = acc_pcm[15:0] + 17'd13564;
        ce_pcm <= sum16[16]; acc_pcm <= {16'd0, sum16[15:0]};
    end else begin
        sum32 = {1'b0, acc_z80} + {1'b0, STD_Z80_INC};
        ce_z80 <= sum32[32]; acc_z80 <= sum32[31:0];
        sum32 = {1'b0, acc_pcm} + {1'b0, STD_PCM_INC};
        ce_pcm <= sum32[32]; acc_pcm <= sum32[31:0];
    end
end

// FM remains free-running through board/ROM reset so JT12's enabled-clock
// reset rings advance. Only PLL loss stops and rephases this independent NCO.
always @(posedge clk) begin : fm_nco
    logic [32:0] sum32;
    logic [16:0] sum16;
    if (!pll_locked) begin
        ce_fm <= 1'b0; acc_fm <= 32'd0;
    end else if (is_multi32) begin
        sum16 = acc_fm[15:0] + 17'd10851;
        ce_fm <= sum16[16]; acc_fm <= {16'd0, sum16[15:0]};
    end else begin
        sum32 = {1'b0, acc_fm} + {1'b0, STD_Z80_INC};
        ce_fm <= sum32[32]; acc_fm <= sum32[31:0];
    end
end
endmodule
