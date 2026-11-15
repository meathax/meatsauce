/* SPDX-License-Identifier: GPL-3.0-or-later */
// Arblst: unchanged 48 MHz fabric, pixel CE /6 and double-pixel CE /3.
// Reuse JTFRAME address scaling: never stretch DAC CE for a 384-pixel line.
module arblst_crt_video #(
    parameter COLORW=5
)(
    input wire clk, reset, pxl_cen, pxl2_cen,
    input wire enable, native_path,
    input wire signed [4:0] hsize, vposition,
    input wire signed [6:0] hposition,
    input wire [COLORW-1:0] r_in,g_in,b_in,
    input wire HS_in,VS_in,HB_in,VB_in,
    output wire [COLORW-1:0] r_out,g_out,b_out,
    output wire HS_out,VS_out,HB_out,VB_out,
    output wire ce_out,active,available,range_clamped
);
    reg vs_old;
    reg enable_q;
    reg signed [4:0] size_q;
    reg signed [4:0] vpos_q;
    reg signed [6:0] hpos_q;
    reg admit_hs_old,blank_pending;
    reg [5:0] blank_lines;
    wire raw_vs_rise=VS_in && !vs_old;
    wire admit_hs_rise=HS_in && !admit_hs_old;
    // Anchor to raw VS, then wait 32 subsequent HSync rises. With the donor
    // VS at 253 this is line 13 of the next frame: after every supported
    // shifted VS pulse (including transport), before visible line 16, and
    // long after the final previous-frame buffered visible row has drained.
    // Both control stages and active-mode warmup use this SAME boundary.
    wire frame_boundary=pxl_cen && blank_pending && admit_hs_rise &&
                        blank_lines==6'd31 && VB_in;
    always @(posedge clk) begin
        if(reset) begin
            vs_old<=0;admit_hs_old<=0;blank_pending<=0;blank_lines<=0;
            enable_q<=0;size_q<=0;vpos_q<=0;hpos_q<=0;
        end else begin
            if(pxl_cen)begin
                vs_old<=VS_in;admit_hs_old<=HS_in;
                if(raw_vs_rise)begin blank_pending<=1;blank_lines<=0;end
                else if(blank_pending && admit_hs_rise)begin
                    if(blank_lines==6'd31)blank_pending<=0;
                    else blank_lines<=blank_lines+6'd1;
                end
            end
            if(frame_boundary)begin
                enable_q<=enable && native_path;
                size_q<=hsize < -5'sd2 ? -5'sd2 : hsize > 5'sd2 ? 5'sd2 : hsize;
                hpos_q<=hposition;
                vpos_q<=vposition;
            end
        end
    end
    wire [3:0] donor_scale=-size_q;
    wire [COLORW-1:0] sr,sg,sb;
    wire shs,svs,shb,svb;
    // JTFRAME's RGB read bank contains the line completed at the preceding
    // HSync. Carry its VBlank to the next active start, rather than admitting
    // the current input line's blanking. Hold it through HSync so the following
    // position buffer captures the blanking of the RGB line it just completed.
    reg hs_old,hb_old,bank_vb,size_vb;
    always @(posedge clk)begin
        if(reset)begin hs_old<=0;hb_old<=1;bank_vb<=1;size_vb<=1;end
        else if(pxl_cen)begin
            hs_old<=HS_in;hb_old<=HB_in;
            if(HS_in&&!hs_old)bank_vb<=VB_in;
            if(!HB_in&&hb_old)size_vb<=bank_vb;
        end
    end
    wire scaled_vb=enable_q && size_q!=0 ? size_vb : svb;
    // Preserve the existing JTFRAME Off-path register latency.
    jtframe_hsize #(.COLORW(COLORW)) u_size(
        .clk,.pxl_cen,.pxl2_cen,.scale(donor_scale),.offset(5'd0),
        .enable(enable_q && size_q!=0),
        .r_in,.g_in,.b_in,.HS_in,.VS_in,.HB_in,.VB_in,
        .r_out(sr),.g_out(sg),.b_out(sb),
        .HS_out(shs),.VS_out(svs),.HB_out(shb),.VB_out(svb)
    );
    // Pad to eight bits without changing the source color precision.
    wire [23:0] rgb_in={sr,{(8-COLORW){1'b0}},sg,{(8-COLORW){1'b0}},sb,{(8-COLORW){1'b0}}};
    wire [23:0] rgb_out;
    arblst_native_crt_adjust #(
        .PIXEL_DIV(6),.HTOTAL(512),.VTOTAL(272),
        .HACTIVE_START(4),.HS_REFERENCE(409),
        .HSIZE_MIN(0),.HSIZE_MAX(0),
        .HPOS_MIN(-16),.HPOS_MAX(15),.VPOS_MIN(-16),.VPOS_MAX(15)
    ) u_position(
        .clk,.reset,.native_frame_boundary(frame_boundary),
        .native_timing_valid(1'b1),.native_profile(1'b1),
        .path_selected(native_path),.scandoubler_enabled(1'b0),.quarter_turn_selected(1'b0),
        .enable(enable_q),.hsize(5'sd0),.hposition(hpos_q),.vposition(vpos_q),
        .ce_in(pxl_cen),.rgb_in,.hs_in(shs),.vs_in(svs),.hb_in(shb),.vb_in(scaled_vb),
        .ce_out,.rgb_out,.hs_out(HS_out),.vs_out(VS_out),.hb_out(HB_out),.vb_out(VB_out),
        .active,.available,.range_clamped
    );
    assign r_out=rgb_out[23 -: COLORW];
    assign g_out=rgb_out[15 -: COLORW];
    assign b_out=rgb_out[7 -: COLORW];
endmodule
