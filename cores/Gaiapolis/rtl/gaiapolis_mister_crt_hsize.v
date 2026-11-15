/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 1-8-2021 */

// Applies horizontal scaling to an analogue signal

// Adapted from JTFRAME jtframe_hsize: keep the output pixel cadence fixed and
// use a wider signed read step for the five Heavy Unit size selections.
module gaiapolis_mister_crt_hsize #( parameter
    COLORW     =4     // bits per colour
    //VIDEO_WIDTH=256   // screen pixel width (excluding blanking)
) (
    input              clk,
    input              pxl_cen,
    input              pxl2_cen,

    input  signed [5:0] scale,
    input  signed [6:0] offset,
    input              enable,

    input [COLORW-1:0] r_in,
    input [COLORW-1:0] g_in,
    input [COLORW-1:0] b_in,
    input              HS_in,
    input              VS_in,
    input              HB_in,
    input              VB_in,
    // filtered video
    output reg            HS_out,
    output reg            VS_out,
    output reg            HB_out,
    output reg            VB_out,
    output reg [COLORW-1:0] r_out,
    output reg [COLORW-1:0] g_out,
    output reg [COLORW-1:0] b_out
);

//localparam VW = VIDEO_WIDTH <= 256 ? 9 : (VIDEO_WIDTH <= 512 ? 9 : 10);
localparam VW = 9; // Max 512 pixels including blanking
localparam SW = 8;

wire [   VW+SW-2:0] summand;
wire [COLORW*3-1:0] rgb_out, rgb_in;
reg  [        VW:0] rdcnt_l=0, rdcnt=0,rgbcnt_i=0;
reg  [      SW-2:0] rdfrac=0,rgbfrac=0;
reg  [      VW-1:0] hb0, hb1;
reg  [      VW-1:0] wrcnt, hmax;
reg signed [VW:0] rgbcnt;

reg  VSl, HSl, LHBl, LHBll, VBl, pass, over;

assign rgb_in  = {r_in, g_in, b_in};
wire signed [7:0] read_step = 8'sd64 + {{2{scale[5]}},scale};
assign summand = {{(VW+SW-9){1'b0}},read_step};
wire signed [VW+1:0] centre_delta = $signed({2'b00,hmax}) - $signed({1'b0,rdcnt_l});

always @(posedge clk) if(pxl_cen) begin
    HSl    <=  HS_in;
    LHBl   <= ~HB_in;
    LHBll  <=  LHBl;
    HB_out <= enable ? (~pass | HS_in) : HB_in;
    HS_out <= HS_in;
    VB_out <= VB_in;

    // VB must be adjusted to prevent the bottom line from being washed out
    if( ~HB_in & ~LHBl ) {VB_out, VBl} <= {VBl, VB_in};
    if(  HS_in & ~HSl ) begin
        wrcnt  <= 0;
        hmax   <= wrcnt;
        VSl    <= VS_in;
        VS_out <= VSl;
    end else begin
        wrcnt  <= wrcnt + 1'd1;
    end
    if( !enable) begin
        VB_out <= VB_in;
        VS_out <= VS_in;
    end
    // Register when HB toggles
    if(  LHBl   & ~LHBll  ) hb1 <= wrcnt;
    if(  HB_in  &  LHBl   ) hb0 <= wrcnt;
    // colour output
    {r_out,g_out,b_out} <= enable ? (pass && !HS_in ? rgb_out : {3*COLORW{1'b0}}) : rgb_in;
end

always @(posedge clk) if(pxl2_cen) begin
    {rdcnt,rdfrac} <= {rdcnt,rdfrac} + {1'b0,summand};
    pass           <= !rgbcnt[VW] && (rgbcnt[VW-1:0] <= hb0) && (rgbcnt[VW-1:0] >= hb1);
    if( ~HS_in &  HSl)     over <= 1;
    if(  HS_in & ~HSl & over) begin
        {rdcnt,rdfrac} <= { {VW-6{offset[6]}}, offset,{SW-1{1'b0}} };
        rdcnt_l        <= rdcnt;
        rgbcnt         <= rgbcnt_i;
        rgbfrac        <= 0;
        rgbcnt_i       <= centre_delta >>> 1;
        over           <= 0; //Avoids this step being done twice in the same HS
    end else begin
        {rgbcnt,rgbfrac} <= {rgbcnt,rgbfrac} + summand;
    end
end

jtframe_linebuf #(.DW(COLORW*3), .AW(VW)) u_line(
    .clk      ( clk          ),
    .LHBL     (~HS_in        ),
    // Port 0: writes
    .wr_data  ( rgb_in       ),
    .wr_addr  ( wrcnt ),
    .we       ( pxl_cen      ),
    // Port 1
    .rd_addr  (rgbcnt[VW-1:0]),
    .rd_gated (              ),
    .rd_data  ( rgb_out      )
    );
endmodule
