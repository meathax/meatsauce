// SPDX-License-Identifier: GPL-3.0-or-later
// Nearest-pixel horizontal geometry at the unchanged, integer pixel CE.
// Two scanline banks add one line only in the enabled geometry path.
module bigfight_crt_size(
    input wire clk, reset, ce_in,
    input wire [8:0] x, y,
    input wire [2:0] size_option,
    input wire [23:0] rgb_in,
    input wire hs_in,vs_in,hb_in,vb_in,
    output reg ce_out,hs_out,vs_out,hb_out,vb_out,
    output reg [23:0] rgb_out,
    output wire [8:0] active_width
);
    reg [2:0] mode=0;
    reg [8:0] width=320, source_x=0;
    reg [9:0] remainder=0;
    wire [23:0] line_rgb;
    assign active_width=width;
    wire enabled=mode!=0;
    wire [9:0] sum=remainder+10'd320;
    // Read both completed-line candidates synchronously. Selecting by y
    // after the RAMs preserves the first pixel when line parity changes.
    // source_x changes only at CE8, so these pre-reads settle before the next
    // consumed pixel. Full 24-bit RGB and the original output tuple remain.
    (* ramstyle="M10K" *) reg [23:0] even_line[0:319],odd_line[0:319];
    reg [23:0] even_q,odd_q;
    assign line_rgb=y[0]?even_q:odd_q;
    always @(posedge clk)begin
        if(!reset && ce_in && x<320 && y<240)begin
            if(y[0])odd_line[x]<=rgb_in;
            else even_line[x]<=rgb_in;
        end
        even_q<=even_line[source_x];
        odd_q<=odd_line[source_x];
    end
    always @(posedge clk) begin
        ce_out<=ce_in;
        if(reset) begin mode<=0;width<=320;source_x<=0;remainder<=0;ce_out<=0;end
        else if(ce_in) begin
            if(x==0 && y==250) begin
                mode<=size_option<=4 ? size_option : 0;
                case(size_option)
                    1:width<=328;2:width<=336;3:width<=304;4:width<=312;
                    default:width<=320;
                endcase
            end
            hs_out<=hs_in;vs_out<=vs_in;
            if(!enabled) begin
                rgb_out<=rgb_in;hb_out<=hb_in;vb_out<=vb_in;
            end else begin
                hb_out<=x>=width;vb_out<=y==0 || y>240;
                rgb_out<=(x<width && y>=1 && y<=240) ? line_rgb : 24'd0;
            end
            if(x>=width-1) begin source_x<=0;remainder<=0;end
            else if(sum >= {1'b0,width}*2) begin
                source_x<=source_x+2;remainder<=sum-{1'b0,width}*2;
            end else if(sum >= width) begin
                source_x<=source_x+1;remainder<=sum-width;
            end else remainder<=sum;
        end
    end
endmodule
