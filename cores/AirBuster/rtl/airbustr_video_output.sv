// SPDX-License-Identifier: GPL-3.0-or-later
// Same-pixel metadata alignment for the actual Heavy Unit renderer's latency.
// A coordinate sampled at master edgeN produces RGB at edgeN+3. Four sampled
// metadata stages match that edge, with no extra RGB register and no new clock.
module airbustr_video_output #(
    parameter bit HS_IDLE = 1'b1,
    parameter bit VS_IDLE = 1'b1
) (
    input logic clk,reset,
    input logic raw_ce_pixel,raw_hs,raw_vs,raw_hb,raw_vb,raw_de,
    input logic [23:0] renderer_rgb,
    input logic renderer_valid,
    output logic ce_pixel,hs,vs,hb,vb,de,pixel_valid,
    output logic [23:0] rgb,
    output logic alignment_error
);
    logic [5:0] metadata [0:3];
    assign {ce_pixel,hs,vs,hb,vb,de} = metadata[3];
    assign rgb = de ? renderer_rgb : 24'b0;
    assign pixel_valid = ce_pixel && de && renderer_valid;
    always_ff @(posedge clk) begin
        if(reset) begin
            for(integer i=0;i<4;i=i+1) metadata[i] <= {1'b0,HS_IDLE,VS_IDLE,1'b1,1'b1,1'b0};
            alignment_error <= 0;
        end else begin
            metadata[0] <= {raw_ce_pixel,raw_hs,raw_vs,raw_hb,raw_vb,raw_de};
            for(integer i=1;i<4;i=i+1) metadata[i] <= metadata[i-1];
            if((ce_pixel && de && !renderer_valid) || (renderer_valid && (!ce_pixel || !de))) alignment_error <= 1;
        end
    end
endmodule
