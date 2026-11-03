/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 14-2-2026 */

module jtx1010_acc(
    input               clk, cen,
    input        [ 7:0] cfg,
    input        [ 3:0] ch,
    input        [ 4:0] st,
    input signed [15:0] wav_l, wav_r, pcm_l, pcm_r,
    output reg          sample,
    output reg signed [15:0] snd_l, snd_r, mux_l
);

localparam WAV=1;

reg signed [15:0] mux_r, acc_l=0, acc_r=0;

// Saturate instead of wrapping when many loud voices sum.
function automatic signed [15:0] sat(input signed [16:0] v);
    sat = v[16]==v[15] ? v[15:0] : {v[16],{15{~v[16]}}};
endfunction

always_comb begin
    mux_l = cfg[WAV] ? wav_l : pcm_l;
    mux_r = cfg[WAV] ? wav_r : pcm_r;
end

always_ff @(posedge clk) if(cen) begin
    sample <= 0;
    if(st==31) begin
        sample <= 1;
        if(ch==0) begin
            snd_l <= acc_l;
            snd_r <= acc_r;
            acc_l <= mux_l;
            acc_r <= mux_r;
        end else begin
            acc_l <= sat(acc_l + mux_l);
            acc_r <= sat(acc_r + mux_r);
        end
    end
end

endmodule
