// SPDX-License-Identifier: GPL-3.0-or-later
// Argus draft/JTFRAME adaptation; reference arithmetic: MAME0.289 jalblend.cpp.
package argus_video_math;
    function automatic logic [7:0] expand4(input logic [3:0] c);
        expand4 = {c,c};
    endfunction

    function automatic logic [7:0] clamp_channel(
        input logic [7:0] dst, src, input logic subtract);
        logic [8:0] sum;
        begin
            sum = {1'b0,dst} + {1'b0,src};
            clamp_channel = subtract ? (dst < src ? 8'd0 : dst-src)
                                     : (sum[8] ? 8'hff : sum[7:0]);
        end
    endfunction

    function automatic logic [23:0] add_sub_rgb(
        input logic [23:0] dst, src, input logic [2:0] signs);
        add_sub_rgb = {clamp_channel(dst[23:16],src[23:16],signs[2]),
                       clamp_channel(dst[15:8],src[15:8],signs[1]),
                       clamp_channel(dst[7:0],src[7:0],signs[0])};
    endfunction

    function automatic logic [23:0] sprite_blend(
        input logic [23:0] dst, src, input logic [3:0] alpha);
        sprite_blend = alpha[3] ? add_sub_rgb(dst,src,alpha[2:0]) : src;
    endfunction

    function automatic logic [23:0] palette_rgb(input logic [7:0] lo, hi);
        palette_rgb = {expand4(lo[7:4]),expand4(lo[3:0]),expand4(hi[7:4])};
    endfunction

    function automatic logic [23:0] background_effect(
        input logic [23:0] src, input logic grey, input logic [15:0] intensity);
        logic [9:0] sum;
        (* multstyle="dsp" *) logic [19:0] average_product;
        logic [7:0] avg;
        logic [23:0] base, delta;
        begin
            sum = {2'b0,src[23:16]} + {2'b0,src[15:8]} + {2'b0,src[7:0]};
            average_product = {10'd0,sum} * 20'd683;
            avg = 8'(average_product >> 11);
            base = grey ? {avg,avg,avg} : src;
            delta = {expand4(intensity[15:12]),expand4(intensity[11:8]),
                     expand4(intensity[7:4])};
            // The explicit-alpha MAME overload always performs add/subtract,
            // including when intensity bit3 is clear.
            background_effect = add_sub_rgb(base,delta,intensity[2:0]);
        end
    endfunction

    function automatic logic [23:0] gfx_byte_offset(
        input logic [11:0] code, input logic text8,
        input logic [3:0] x, y);
        // 16x16 layout: column-major 8x8 groups 0 2 / 1 3.
        // Each half-column has sixteen four-byte rows; MSB nibble is first.
        gfx_byte_offset = text8 ? {7'd0,code,5'd0} + {19'd0,y[2:0],2'd0}
                                            + {22'd0,x[2:1]}
                               : {5'd0,code,7'd0} + {17'd0,x[3],6'd0}
                                            + {18'd0,y,2'd0} + {22'd0,x[2:1]};
    endfunction
endpackage
