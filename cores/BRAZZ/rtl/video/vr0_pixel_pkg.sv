// SPDX-License-Identifier: GPL-3.0-or-later
// RGB565 arithmetic derived from the BSD MAME VRender0 reference.
package vr0_pixel_pkg;
    function automatic logic [15:0] rgb565(input logic [23:0] c);
        return {c[23:19],c[15:10],c[7:3]};
    endfunction
    function automatic logic [7:0] channel(input logic [15:0] c, input int i);
        case(i)
            0: return {c[15:11],c[15:13]};
            1: return {c[10:5],c[10:9]};
            default: return {c[4:0],c[4:2]};
        endcase
    endfunction
    function automatic logic [15:0] shade565(input logic [15:0] c, input logic [23:0] shade);
        logic [23:0] value;
        logic [15:0] product;
        for(int i=0;i<3;i++) begin
            product = 16'(channel(c,i)) * 16'(shade[23-i*8 -: 8]);
            value[23-i*8 -: 8] = product[15:8];
        end
        return rgb565(value);
    endfunction
    function automatic logic [8:0] factor(input logic [5:0] mode,
        input logic [7:0] src, dst, src_color, dst_color);
        logic [8:0] f;
        case(mode[4:0])
            5'h02: f={1'b0,src_color};
            5'h04: f={1'b0,src};
            5'h08: f={1'b0,dst_color};
            5'h10: f={1'b0,dst};
            default: f=0;
        endcase
        return mode[5] ? 9'd256-f : f;
    endfunction
    function automatic logic [15:0] alpha565(input logic [15:0] src, dst,
        input logic [5:0] src_mode, dst_mode, input logic [23:0] src_color,dst_color);
        logic [23:0] value;
        logic [7:0] s,d;
        logic [8:0] sm,dm;
        logic [17:0] sum;
        for(int i=0;i<3;i++) begin
            s=channel(src,i); d=channel(dst,i);
            sm=factor(src_mode,s,d,src_color[23-i*8 -: 8],dst_color[23-i*8 -: 8]);
            dm=factor(dst_mode,s,d,src_color[23-i*8 -: 8],dst_color[23-i*8 -: 8]);
            sum=18'(s)*18'(sm)+18'(d)*18'(dm);
            value[23-i*8 -: 8] = (sum[17:8]>10'd255) ? 8'hff : sum[15:8];
        end
        return rgb565(value);
    endfunction
    function automatic logic [15:0] alpha_sum565(
        input logic [2:0][15:0] src_product,dst_product);
        logic [23:0] value;
        logic [17:0] sum;
        for(int i=0;i<3;i++) begin
            sum=18'(src_product[i])+18'(dst_product[i]);
            value[23-i*8 -: 8]=(sum[17:8]>10'd255) ? 8'hff : sum[15:8];
        end
        return rgb565(value);
    endfunction
endpackage
