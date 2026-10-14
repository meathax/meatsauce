// SPDX-License-Identifier: GPL-3.0-or-later
// Two aligned 64-bit bursts supply a 16-pixel row; one supplies text8.
module argus_gfx_row (
    input logic clk_sys, reset,
    input logic start,
    input logic [23:0] base,
    input logic [11:0] code,
    input logic text8, hflip, vflip,
    input logic [3:0] y,
    output logic busy, done,
    output logic [63:0] pixels,
    output logic req,
    output logic [23:0] addr,
    input logic ready,
    input logic [63:0] rdata
);
    import argus_video_math::*;
    logic [23:0] base_l;
    logic [11:0] code_l;
    logic text_l, hflip_l;
    logic [3:0] y_l;
    logic half;
    logic [3:0] width_mask;
    logic [23:0] byte_addr;
    logic [31:0] half_pixels;
    always_comb begin
        width_mask = text_l ? 4'd7 : 4'd15;
        byte_addr = base_l + gfx_byte_offset(code_l,text_l,{half,3'd0},y_l);
        addr = {byte_addr[23:3],3'd0};
        half_pixels = byte_addr[2] ? rdata[63:32] : rdata[31:0];
        req = busy;
    end
    always_ff @(posedge clk_sys) begin
        if (reset) begin
            busy<=0; done<=0; pixels<=0; base_l<=0; code_l<=0;
            text_l<=0; hflip_l<=0; y_l<=0; half<=0;
        end else begin
            done<=0;
            if (start && !busy) begin
                busy<=1; half<=0; pixels<=0; base_l<=base; code_l<=code;
                text_l<=text8; hflip_l<=hflip;
                y_l<=y ^ (vflip ? (text8 ? 4'd7 : 4'd15) : 4'd0);
            end else if (req && ready) begin
                for(integer n=0;n<8;n=n+1) begin
                    // Burst byte0 is bits7:0; high nibble is first pixel.
                    pixels[4*(hflip_l ? width_mask-(4'({half,3'd0})+4'(n)) :
                                       4'({half,3'd0})+4'(n)) +: 4]
                        <= half_pixels[8*(n/2)+(n%2==0 ? 4 : 0) +: 4];
                end
                if (text_l || half) begin
                    busy<=0; done<=1;
                end else half<=1;
            end
        end
    end
endmodule
