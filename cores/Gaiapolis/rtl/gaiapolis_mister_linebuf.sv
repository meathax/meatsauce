// Copyright (c) 2012-2013 Ludvig Strigeus
// Copyright (c) 2017,2018 Sorgelig
// This program is GPL Licensed. See COPYING for the full license.
// Derived from the former HQ2x line buffers; no edge detection/interpolation.
module gaiapolis_mister_linebuf #(parameter LENGTH=1024, HALF_DEPTH=0)(
    input clk, ce_in,
    input [(HALF_DEPTH ? 12 : 24)-1:0] inputpixel,
    input reset_frame, reset_line, ce_out,
    input [1:0] read_y,
    input hblank,
    output [(HALF_DEPTH ? 12 : 24)-1:0] outpixel
);
localparam AWIDTH=$clog2(LENGTH)-1;
localparam W=HALF_DEPTH ? 12 : 24;
reg [W-1:0] input_ram0[0:LENGTH-1], input_ram1[0:LENGTH-1];
reg [W-1:0] q0,q1,wrpix;
reg [AWIDTH:0] offs,wrin_addr;
reg curbuf,wrin_en;
reg [1:0] cyc;
wire [W-1:0] current_pixel=curbuf ? q1 : q0;
reg [W-1:0] current0,current1,current2;
reg [W-1:0] delay0,delay1,delay2,delayed_pixel;
always @(posedge clk) begin
    if(wrin_en) begin
        if(curbuf) input_ram0[wrin_addr]<=wrpix;
        else input_ram1[wrin_addr]<=wrpix;
    end
    q0<=input_ram0[offs]; q1<=input_ram1[offs];
    if(ce_in) begin
        delay0<=current0; delay1<=delay0;
        delay2<=delay1; delayed_pixel<=delay2;
    end
end

// The disabled filter published four identical copies of each source pixel.
// Keep its CE phases/write address, but store one copy and retain output hold.
reg [4*W-1:0] wrdata;
reg [AWIDTH+1:0] wrout_addr,read_x;
reg wrout_en;
reg [W-1:0] output_ram[0:LENGTH*2-1];
reg [W-1:0] output_q;
reg [W-1:0] output_pixel;
assign outpixel=output_pixel;
always @(posedge clk) begin
    if(wrout_en) output_ram[wrout_addr]<=wrdata[W-1:0];
    output_q<=output_ram[{read_x[AWIDTH+1:1],read_y[1]}];
    if(ce_out) begin
        if(read_x[0]) output_pixel<=output_q;
        if(!hblank && !(&read_x)) read_x<=read_x+1'b1;
        if(hblank) read_x<=0;
    end
end
reg old_reset_line,old_reset_frame;
reg [3:0] wrdata_finished;
reg [AWIDTH+1:0] waddr;
always @(posedge clk) begin
    wrout_en<=0; wrin_en<=0;
    if(ce_in) begin
        case(cyc)
            0: wrdata[W-1:0]<=delayed_pixel;
            1: wrdata[2*W-1:W]<=delayed_pixel;
            2: wrdata[4*W-1:3*W]<=delayed_pixel;
            3: wrdata[3*W-1:2*W]<=delayed_pixel;
        endcase
        wrdata_finished<=wrdata_finished<<1;
        if(wrdata_finished[3]) begin wrout_en<=1; wrout_addr<=waddr; end
        if(!(&offs)) begin
            if(cyc==1) begin
                current2<=current_pixel;
                wrpix<=inputpixel; wrin_addr<=offs; wrin_en<=1;
            end
            if(cyc==3) begin offs<=offs+1'b1; waddr<={offs,curbuf}; wrdata_finished[0]<=1; end
        end
        if(cyc==3) begin current0<=current1; current1<=current2; end
        cyc<=cyc+1'b1;
        if(old_reset_line && !reset_line) begin
            old_reset_frame<=reset_frame; offs<=0; cyc<=0; curbuf<=!curbuf;
            current0<=0; current1<=0; current2<=0;
            if(old_reset_frame && !reset_frame) curbuf<=0;
        end
        old_reset_line<=reset_line;
    end
end
endmodule
