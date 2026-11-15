// SPDX-License-Identifier: GPL-3.0-only
// Graphics byte/row packing split from the qualified frozen-renderer frontend.
// Shared layout: tile planes0..5ffff, tileCLUT60000..7ffff,
// spriteL100000..2fffff, spriteH300000..4fffff. Sprite CLUTs are
// the existing final4KiB of their graphics banks, not independent ROM copies.
module bigfight_graphics_rom_lanes (
    input logic clk_sys,cold_reset,
    input logic tile_gfx_req_o,
    output logic tile_gfx_ready_i,
    input logic [16:0] tile_gfx_row_addr_o,
    output logic tile_gfx_rsp_valid_i,
    input logic tile_gfx_rsp_ready_o,
    output logic [23:0] tile_gfx_rsp_data_i,
    input logic tile_clut_req_o,
    output logic tile_clut_ready_i,
    input logic [16:0] tile_clut_row_addr_o,
    output logic tile_clut_rsp_valid_i,
    input logic tile_clut_rsp_ready_o,
    output logic [63:0] tile_clut_rsp_data_i,
    input logic sprite_rom_req_o,
    output logic sprite_rom_ready_i,
    input logic sprite_rom_bank_o,
    input logic [20:0] sprite_rom_byte_addr_o,
    output logic sprite_rom_valid_i,
    output logic [31:0] sprite_rom_data_i,
    input logic sprite_clut_req_o,
    output logic sprite_clut_ready_i,
    input logic [8:0] sprite_clut_color_o,
    output logic sprite_clut_valid_i,
    output logic [127:0] sprite_clut_bytes_i,
    output logic [6:0] lane_req,
    input logic [6:0] lane_ready,
    output logic [7*26-1:0] lane_addresses,
    input logic [6:0] lane_valid,
    output logic [6:0] lane_rsp_ready,
    input logic [7*64-1:0] lane_data
);
    logic [63:0] tile_data;
    logic [63:0] sprite_data;
    logic [127:0] sprite_clut_data;
    logic [2:0] tile_byte_q;
    logic sprite_upper_q;
    wire [25:0] tile_aligned={7'b0,tile_gfx_row_addr_o[16:1],3'b000};
    wire [25:0] sprite_aligned=26'h100000+
        (sprite_rom_bank_o?26'h200000:26'd0)+{5'b0,sprite_rom_byte_addr_o[20:3],3'b000};
    wire [25:0] sprite_color_offset={14'b0,sprite_clut_color_o,3'b000};
    always_ff @(posedge clk_sys) begin
        if(cold_reset)begin tile_byte_q<=0;sprite_upper_q<=0;end
        else begin
            if(tile_gfx_req_o&&tile_gfx_ready_i)tile_byte_q<=tile_gfx_row_addr_o[2:0];
            if(sprite_rom_req_o&&sprite_rom_ready_i)sprite_upper_q<=sprite_rom_byte_addr_o[2];
        end
    end
    genvar p;
    generate for(p=0;p<3;p=p+1)begin:g_tile_byte
        assign tile_gfx_rsp_data_i[8*p+:8]=tile_data[32*tile_byte_q[0]+8*p+:8];
    end endgenerate
    generate for(p=0;p<4;p=p+1)begin:g_sprite_byte
        assign sprite_rom_data_i[31-8*p-:8]=sprite_data[(sprite_upper_q?32:0)+8*p+:8];
    end endgenerate
    generate for(p=0;p<8;p=p+1)begin:g_clut_byte
        assign sprite_clut_bytes_i[127-8*p-:8]=sprite_clut_data[8*p+:8];
        assign sprite_clut_bytes_i[63-8*p-:8]=sprite_clut_data[64+8*p+:8];
    end endgenerate
    bigfight_rom_group64 #(.WAYS(1)) tile_group (
        .clk_sys,.cold_reset,.req_valid_i(tile_gfx_req_o),.req_ready_o(tile_gfx_ready_i),
        .req_addresses_i(tile_aligned),
        .rsp_valid_o(tile_gfx_rsp_valid_i),.rsp_ready_i(tile_gfx_rsp_ready_o),.rsp_data_o(tile_data),
        .wide_req_valid_o(lane_req[0]),.wide_req_ready_i(lane_ready[0]),
        .wide_req_addresses_o(lane_addresses[0+:26]),.wide_rsp_valid_i(lane_valid[0]),
        .wide_rsp_ready_o(lane_rsp_ready[0]),.wide_rsp_data_i(lane_data[0+:64]));
    bigfight_rom_group64 #(.WAYS(1)) tile_clut_group (
        .clk_sys,.cold_reset,.req_valid_i(tile_clut_req_o),.req_ready_o(tile_clut_ready_i),
        .req_addresses_i(26'hd0000+{9'b0,tile_clut_row_addr_o}),
        .rsp_valid_o(tile_clut_rsp_valid_i),.rsp_ready_i(tile_clut_rsp_ready_o),.rsp_data_o(tile_clut_rsp_data_i),
        .wide_req_valid_o(lane_req[3]),.wide_req_ready_i(lane_ready[3]),
        .wide_req_addresses_o(lane_addresses[78+:26]),.wide_rsp_valid_i(lane_valid[3]),
        .wide_rsp_ready_o(lane_rsp_ready[3]),.wide_rsp_data_i(lane_data[192+:64]));
    bigfight_rom_group64 #(.WAYS(1)) sprite_group (
        .clk_sys,.cold_reset,.req_valid_i(sprite_rom_req_o),.req_ready_o(sprite_rom_ready_i),
        .req_addresses_i(sprite_aligned),.rsp_valid_o(sprite_rom_valid_i),.rsp_ready_i(1'b1),.rsp_data_o(sprite_data),
        .wide_req_valid_o(lane_req[4]),.wide_req_ready_i(lane_ready[4]),
        .wide_req_addresses_o(lane_addresses[104+:26]),.wide_rsp_valid_i(lane_valid[4]),
        .wide_rsp_ready_o(lane_rsp_ready[4]),.wide_rsp_data_i(lane_data[256+:64]));
    bigfight_rom_group64 #(.WAYS(2)) sprite_clut_group (
        .clk_sys,.cold_reset,.req_valid_i(sprite_clut_req_o),.req_ready_o(sprite_clut_ready_i),
        .req_addresses_i({26'h4ff000+sprite_color_offset,26'h2ff000+sprite_color_offset}),
        .rsp_valid_o(sprite_clut_valid_i),.rsp_ready_i(1'b1),.rsp_data_o(sprite_clut_data),
        .wide_req_valid_o(lane_req[6:5]),.wide_req_ready_i(lane_ready[6:5]),
        .wide_req_addresses_o(lane_addresses[130+:52]),.wide_rsp_valid_i(lane_valid[6:5]),
        .wide_rsp_ready_o(lane_rsp_ready[6:5]),.wide_rsp_data_i(lane_data[320+:128]));
    assign lane_req[2:1]=2'b00;
    assign lane_addresses[26+:52]='0;
    assign lane_rsp_ready[2:1]=2'b11;
endmodule
