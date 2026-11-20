// SPDX-License-Identifier: BSD-3-Clause
// Raw Galastrm sprite ROM -> JTFRAME planar row words for both row halves.
// One immutable aligned 64-bit line contains both eight-pixel row halves; a
// reply returns {half 1, half 0}. Split transaction pass-through: ACK accepts a
// request, RVALID returns replies in accept order.
module gs_sprite_rom64(
    input wire req,
    input wire [19:0] address,
    output wire ack,
    output wire rvalid,
    output wire [63:0] data,
    output wire raw_req,
    output wire [21:0] raw_address,
    input wire raw_ack,
    input wire raw_rvalid,
    input wire [63:0] raw_data
);
    assign raw_req=req;
    assign raw_address={address[19:5],address[3:0],3'b0};
    assign ack=raw_ack;
    assign rvalid=raw_rvalid;
    genvar half,plane,bit_index;
    generate for(half=0;half<2;half=half+1) begin: halves
        for(plane=0;plane<4;plane=plane+1) begin: planes
            wire [7:0] source_byte=half ? raw_data[plane*16 +: 8] : raw_data[plane*16+8 +: 8];
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin: bits
                assign data[32*half+(3-plane)*8+bit_index]=source_byte[7-bit_index];
            end
        end
    end endgenerate
endmodule
