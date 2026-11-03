// SPDX-License-Identifier: GPL-3.0-or-later
// Palette RAM/pipelining adapted from jtaliens_colmix; priority follows spy.cpp.
module spy_colmix (
    input logic clk, reset, pxl_cen, video_enable,
    input logic lhbl, lvbl, hs, vs,
    input logic [8:0] hdump, vdump,
    input logic cpu_we,
    input logic [10:0] cpu_addr,
    input logic [7:0] cpu_dout,
    output wire [7:0] cpu_din,
    input logic [7:0] f_pxl,
    input logic [11:0] a_pxl, b_pxl, o_pxl,
    input logic f_blank_n, b_blank_n, o_blank_n, shadow,
    output logic [7:0] red, green, blue,
    output wire out_cen, out_hs, out_vs, out_lhbl, out_lvbl,
    output wire [8:0] out_hdump, out_vdump,
    output logic [9:0] palette_index
);
    logic [9:0] index;
    logic shade, shade_latched;
    logic [2:0] cen_pipe, hs_pipe, vs_pipe, hb_pipe, vb_pipe;
    logic [8:0] h_pipe[0:2], v_pipe[0:2];
    wire [7:0] cpu_hi, cpu_lo, pixel_hi, pixel_lo;
    // MAME's palette interface allocates a standard RGB rainbow before the
    // first write to each entry. Raw palette RAM still starts at zero.
    logic written[0:1023];
    logic pixel_written;
    wire [15:0] cold_colour={1'b0,{5{palette_index[2]}},{5{palette_index[1]}},{5{palette_index[0]}}};
    wire [15:0] colour=pixel_written ? {pixel_hi,pixel_lo} : cold_colour;
    integer entry;
    initial for(entry=0;entry<1024;entry=entry+1) written[entry]=0;
    always_ff @(posedge clk) begin
        if(cpu_we) written[cpu_addr[10:1]]<=1;
        pixel_written<=written[palette_index];
    end
    // 857A10/U26: the visible background selects the object's priority bit.
    // With opaque B, OB9 controls the object; otherwise OB8 controls it.
    wire sprite_visible=(o_blank_n || shadow) &&
                        (b_blank_n ? o_pxl[9] : !o_pxl[8]);
    always_comb begin
        index={4'b0000,a_pxl[5:4],a_pxl[3:0]};
        shade=0;
        if(b_blank_n) index={2'b01,2'b00,b_pxl[5:4],b_pxl[3:0]};
        if(sprite_visible) begin
            if(shadow) shade=1;
            else index={2'b10,o_pxl[7:4],o_pxl[3:0]};
        end
        if(f_blank_n) begin index={2'b11,2'b00,f_pxl[5:4],f_pxl[3:0]}; shade=0; end
        if(!video_enable) begin index=10'h300; shade=0; end
    end
    assign cpu_din=cpu_addr[0] ? cpu_lo : cpu_hi;
    jtframe_dual_ram #(.AW(10),.SIMHEXFILE("rtl/video/palette_zero.hex"),.SYNFILE("rtl/video/palette_zero.hex")) u_hi (
        .clk0(clk),.addr0(cpu_addr[10:1]),.data0(cpu_dout),.we0(cpu_we && !cpu_addr[0]),.q0(cpu_hi),
        .clk1(clk),.addr1(palette_index),.data1(8'd0),.we1(1'b0),.q1(pixel_hi));
    jtframe_dual_ram #(.AW(10),.SIMHEXFILE("rtl/video/palette_zero.hex"),.SYNFILE("rtl/video/palette_zero.hex")) u_lo (
        .clk0(clk),.addr0(cpu_addr[10:1]),.data0(cpu_dout),.we0(cpu_we && cpu_addr[0]),.q0(cpu_lo),
        .clk1(clk),.addr1(palette_index),.data1(8'd0),.we1(1'b0),.q1(pixel_lo));
    function automatic [7:0] expand(input [4:0] component,input dim);
        logic [7:0] shadow;
        begin
            // Exact floor(0.6 * {component,component[4:2]}) without a divider.
            case(component)
                5'd0: shadow=8'd0;
                5'd1: shadow=8'd4;
                5'd2: shadow=8'd9;
                5'd3: shadow=8'd14;
                5'd4: shadow=8'd19;
                5'd5: shadow=8'd24;
                5'd6: shadow=8'd29;
                5'd7: shadow=8'd34;
                5'd8: shadow=8'd39;
                5'd9: shadow=8'd44;
                5'd10: shadow=8'd49;
                5'd11: shadow=8'd54;
                5'd12: shadow=8'd59;
                5'd13: shadow=8'd64;
                5'd14: shadow=8'd69;
                5'd15: shadow=8'd73;
                5'd16: shadow=8'd79;
                5'd17: shadow=8'd84;
                5'd18: shadow=8'd88;
                5'd19: shadow=8'd93;
                5'd20: shadow=8'd99;
                5'd21: shadow=8'd103;
                5'd22: shadow=8'd108;
                5'd23: shadow=8'd113;
                5'd24: shadow=8'd118;
                5'd25: shadow=8'd123;
                5'd26: shadow=8'd128;
                5'd27: shadow=8'd133;
                5'd28: shadow=8'd138;
                5'd29: shadow=8'd143;
                5'd30: shadow=8'd148;
                5'd31: shadow=8'd153;
                default: shadow=8'hxx;
            endcase
            expand=dim ? shadow : {component,component[4:2]};
        end
    endfunction
    assign out_cen=cen_pipe[2];
    assign out_hs=hs_pipe[2]; assign out_vs=vs_pipe[2];
    assign out_lhbl=hb_pipe[2]; assign out_lvbl=vb_pipe[2];
    assign out_hdump=h_pipe[2]; assign out_vdump=v_pipe[2];
    integer i;
    always_ff @(posedge clk) begin
        if(reset) begin
            cen_pipe<=0; hs_pipe<=0; vs_pipe<=0; hb_pipe<=0; vb_pipe<=0;
            palette_index<=0; shade_latched<=0; red<=0; green<=0; blue<=0;
            for(i=0;i<3;i=i+1) begin h_pipe[i]<=0; v_pipe[i]<=0; end
        end else begin
            cen_pipe<={cen_pipe[1:0],pxl_cen};
            hs_pipe<={hs_pipe[1:0],hs}; vs_pipe<={vs_pipe[1:0],vs};
            hb_pipe<={hb_pipe[1:0],lhbl}; vb_pipe<={vb_pipe[1:0],lvbl};
            h_pipe[0]<=hdump; v_pipe[0]<=vdump;
            for(i=1;i<3;i=i+1) begin h_pipe[i]<=h_pipe[i-1]; v_pipe[i]<=v_pipe[i-1]; end
            if(pxl_cen) begin palette_index<=index; shade_latched<=shade; end
            if(cen_pipe[1]) begin
                red<=expand(colour[4:0],shade_latched);
                green<=expand(colour[9:5],shade_latched);
                blue<=expand(colour[14:10],shade_latched);
            end
        end
    end
endmodule
