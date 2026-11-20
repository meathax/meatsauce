// SPDX-License-Identifier: BSD-3-Clause
// Exact finite-normal binary32 packing, split at leading-bit detection,
// significand alignment, round-to-nearest/even and exponent packing.
module gs_audio_pack_pipe #(parameter MW=44)(
    input wire clk,reset,req,sign,input wire [MW-1:0] magnitude,
    input wire signed [10:0] base,output reg valid,output reg [31:0] value
);
    function automatic [5:0] highest(input [MW-1:0] mag);
        reg [63:0] scan;
        begin
            scan=mag;highest=0;
            if(|scan[63:32])begin scan=scan>>32;highest=highest+32;end
            if(|scan[31:16])begin scan=scan>>16;highest=highest+16;end
            if(|scan[15:8])begin scan=scan>>8;highest=highest+8;end
            if(|scan[7:4])begin scan=scan>>4;highest=highest+4;end
            if(|scan[3:2])begin scan=scan>>2;highest=highest+2;end
            if(scan[1])highest=highest+1'b1;
        end
    endfunction
    reg v1,v2,v3,s1,s2,s3,z1,z2,z3;
    reg [MW-1:0] m1;
    reg [5:0] top1,top2,top3;
    reg signed [10:0] base1,base2,base3;
    reg [24:0] q2,q3;
    reg guard2,sticky2;
    localparam NW=MW<24 ? 24:MW;
    localparam [5:0] ALIGN_TOP=NW-1;
    wire [NW-1:0] extended_magnitude={{(NW-MW){1'b0}},m1};
    wire [NW-1:0] aligned_magnitude=extended_magnitude<<(ALIGN_TOP-top1);
    wire aligned_guard,aligned_sticky;
    generate
        if(NW>24)begin assign aligned_guard=aligned_magnitude[NW-25];end
        else begin assign aligned_guard=1'b0;end
        if(NW>25)begin assign aligned_sticky=|aligned_magnitude[NW-26:0];end
        else begin assign aligned_sticky=1'b0;end
    endgenerate
    wire [7:0] exponent=$signed({1'b0,top3})+base3+11'sd127+q3[24];
    always @(posedge clk)begin
        v1<=req;v2<=v1;v3<=v2;valid<=v3;
        m1<=magnitude;top1<=highest(magnitude);base1<=base;s1<=sign;z1<=magnitude==0;
        top2<=top1;base2<=base1;s2<=s1;z2<=z1;
        // Normalize once; guard/sticky come from fixed slices. The same
        // pipeline registers and four-clock result schedule are retained.
        q2<={1'b0,aligned_magnitude[NW-1 -:24]};
        guard2<=aligned_guard;sticky2<=aligned_sticky;
        q3<=q2+(guard2 && (sticky2 || q2[0]));top3<=top2;base3<=base2;s3<=s2;z3<=z2;
        value<=z3 ? 0:{s3,exponent,(q3[24] ? q3[23:1]:q3[22:0])};
        if(reset)begin v1<=0;v2<=0;v3<=0;valid<=0;value<=0;end
    end
endmodule
