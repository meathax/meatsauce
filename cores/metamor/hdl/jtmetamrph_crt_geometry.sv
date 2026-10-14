// SPDX-License-Identifier: GPL-3.0-or-later
// Core-side wrapper for rmonic79's CRT Adjust, adapted from Simple156's glue.
// Native 96MHz/6MHz pixel ratio, 384x264 / 288x224. No generated clock.
// Geometry is measured from HS/HBlank, not Simple156's 512x274 offset tables.
module jtmetamrph_crt_geometry(
    input wire clk,reset,ce_in,active,
    input wire signed [4:0] hsize,hposition,vposition,
    input wire [7:0] red_in,green_in,blue_in,
    input wire hs_in,vs_in,hblank_in,vblank_in,
    output wire ce_out,hs_out,vs_out,hblank_out,vblank_out,
    output wire [7:0] red_out,green_out,blue_out
);
    localparam integer BASE=64; // quarter-clocks per native pixel: 16*4
    reg active_q=0;
    reg signed [4:0] hs_q=0,hp_q=0,vp_q=0;
    reg prev_hs=0,prev_vs=0,prev_hb=1;
    reg [9:0] count=0,first=0,last=0,high_count=0;
    reg [9:0] line_length=0,active_first=0,active_last=0,high_length=0;
    reg [1:0] observed=0;
    wire hs_rise=ce_in && hs_in && !prev_hs;
    wire vs_rise=ce_in && vs_in && !prev_vs;
    wire geometry_ok=(observed==2 && line_length==384 && active_last-active_first==288);
    wire [7:0] period=8'd64+{{3{hs_q[4]}},hs_q};
    reg [7:0] phase=0;
    wire [8:0] phase_next={1'b0,phase}+9'd4;
    wire tick=phase_next>={1'b0,period};
    wire live=active_q && geometry_ok && !reset;
    wire read_ce=live ? tick : ce_in;
    always @(posedge clk) begin
        if(reset) begin
            active_q<=0; hs_q<=0; hp_q<=0; vp_q<=0;
            prev_hs<=0;prev_vs<=0;prev_hb<=1;
            count<=0;first<=0;last<=0;high_count<=0;
            line_length<=0;active_first<=0;active_last<=0;high_length<=0;observed<=0;
            phase<=0;
        end else begin
            if(ce_in) begin
                prev_hs<=hs_in;prev_vs<=vs_in;prev_hb<=hblank_in;
                if(vs_rise) begin
                    active_q<=active;
                    hs_q<=hsize>5'sd6 ? 5'sd6 : hsize<-5'sd10 ? -5'sd10 : hsize;
                    hp_q<=hposition;vp_q<=vposition;
                end
                if(!hblank_in && prev_hb) first<=count;
                if(hblank_in && !prev_hb) last<=count;
                if(hs_rise) begin
                    line_length<=count+1'b1;active_first<=first;active_last<=last;
                    high_length<=high_count;count<=0;high_count<=0;
                    if(observed!=2) observed<=observed+1'b1;
                end else begin
                    count<=count+1'b1;
                    if(hs_in) high_count<=high_count+1'b1;
                end
            end
            if(hs_rise) phase<=0;
            else if(tick) phase<=phase_next-{1'b0,period};
            else phase<=phase_next[7:0];
        end
    end

    // Three small serial divisions per line. They finish in 48 clocks during
    // HBlank; no combinational divider or multiplier enters the pixel path.
    reg [1:0] operation=0;
    reg [4:0] bits_left=0;
    reg [15:0] numerator=0,quotient=0;
    reg [8:0] remainder=0;
    reg [7:0] divisor=64;
    reg [15:0] low_numerator=0,high_numerator=0;
    reg signed [11:0] centre=0,minimum=0;
    reg signed [8:0] offset_q=0;
    wire [9:0] width=active_last-active_first;
    wire positive_sync=high_length<(line_length>>1);
    wire [9:0] safe_first=positive_sync ? high_length+2'd2 : 10'd2;
    wire [9:0] safe_last=positive_sync ? line_length-3'd3 : high_length-3'd3;
    wire [9:0] centre_pixel=active_first+(width>>1);
    wire [9:0] div_trial={remainder,numerator[15]};
    wire subtract=div_trial>={2'b0,divisor};
    wire [8:0] remainder_next=subtract ? div_trial-{2'b0,divisor} : div_trial;
    wire [15:0] quotient_next={quotient[14:0],subtract};
    wire signed [11:0] highest=$signed({1'b0,quotient_next[10:0]})-
                                $signed({2'b0,active_last})-12'sd3;
    wire signed [11:0] wanted=centre+$signed({{6{hp_q[4]}},hp_q,1'b0});
    wire signed [11:0] bounded=wanted<minimum ? minimum : wanted>highest ? highest : wanted;
    always @(posedge clk) begin
        if(reset) begin
            operation<=0;bits_left<=0;offset_q<=0;quotient<=0;remainder<=0;
        end else if(hs_rise && geometry_ok) begin
            numerator<={centre_pixel,6'b0}+{9'd0,period[7:1]};
            low_numerator<={safe_first,6'b0}+{8'd0,period}-16'd1;
            high_numerator<={safe_last,6'b0};
            divisor<=period; quotient<=0; remainder<=0;bits_left<=16;operation<=0;
        end else if(bits_left!=0) begin
            numerator<={numerator[14:0],1'b0};quotient<=quotient_next;
            remainder<=remainder_next;bits_left<=bits_left-1'b1;
            if(bits_left==1) begin
                if(operation==0) begin
                    centre<=$signed({1'b0,quotient_next[10:0]})-
                             $signed({2'b0,(width>>1)})-$signed({2'b0,active_first})-12'sd1;
                    numerator<=low_numerator;operation<=1;bits_left<=16;quotient<=0;remainder<=0;
                end else if(operation==1) begin
                    minimum<=$signed({1'b0,quotient_next[10:0]})-$signed({2'b0,active_first});
                    numerator<=high_numerator;operation<=2;bits_left<=16;quotient<=0;remainder<=0;
                end else begin
                    offset_q<=bounded<-12'sd256 ? -9'sd256 : bounded>12'sd255 ? 9'sd255 : bounded[8:0];
                end
            end
        end
    end

    wire [7:0] cr,cg,cb;
    wire chs,cvs,chb,cvb,unused_ref;
    jtmetamrph_crt_adjust #(.VTOTAL(264),.HTOTAL(384),.HPOS_MODE(1)) u_adjust(
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(live),
        .hsize(hs_q),.hoffset(offset_q),.voffset({vp_q[4],vp_q}),
        .r_in(red_in),.g_in(green_in),.b_in(blue_in),
        .hs_in(hs_in),.vs_in(vs_in),.hb_in(hblank_in),.vb_in(vblank_in),
        .r_out(cr),.g_out(cg),.b_out(cb),.hs_out(chs),.vs_out(cvs),
        .hb_out(chb),.vb_out(cvb),.hs_ref_out(unused_ref)
    );
    assign ce_out=reset ? 1'b0 : read_ce;
    assign red_out=reset ? 8'd0 : live ? cr : red_in;
    assign green_out=reset ? 8'd0 : live ? cg : green_in;
    assign blue_out=reset ? 8'd0 : live ? cb : blue_in;
    assign hs_out=reset ? 1'b0 : live ? chs : hs_in;
    assign vs_out=reset ? 1'b0 : live ? cvs : vs_in;
    assign hblank_out=reset ? 1'b1 : live ? chb : hblank_in;
    assign vblank_out=reset ? 1'b1 : live ? cvb : vblank_in;
endmodule
