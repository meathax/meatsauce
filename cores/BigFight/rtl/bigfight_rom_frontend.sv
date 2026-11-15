// SPDX-License-Identifier: GPL-3.0-only
// Shared logical-ROM service. All ten cache lanes use one clk_sys and one
// immutable-byte backend. cold_reset must flush that backend as well.
module bigfight_rom_frontend (
    input logic clk_sys,cold_reset,
    // Audio-only reset cancels delivery, but drains accepted transport reads.
    input logic audio_reset_i,
    input logic program_req_i,
    output logic program_req_ready_o,
    input logic program_master_i,
    input logic [19:0] program_word_address_i,
    output logic program_rsp_valid_o,
    input logic program_rsp_ready_i,
    output logic [15:0] program_rsp_data_o,
    input logic audio_req_i,
    output logic audio_req_ready_o,
    input logic [15:0] audio_byte_address_i,
    output logic audio_rsp_valid_o,
    output logic [7:0] audio_rsp_data_o,
    input logic oki_req_i,
    output logic oki_req_ready_o,
    input logic [17:0] oki_byte_address_i,
    output logic oki_rsp_valid_o,
    output logic [7:0] oki_rsp_data_o,
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
    output logic backend_req_valid,
    input logic backend_req_ready,
    output logic [25:0] backend_req_address,
    input logic backend_rsp_valid,
    output logic backend_rsp_ready,
    input logic [63:0] backend_rsp_data
);
    logic [9:0] lane_req,lane_ready,lane_valid,lane_rsp_ready;
    logic [10*26-1:0] lane_addresses;
    logic [10*64-1:0] lane_data;
    logic [1:0] audio_outstanding_q,audio_discard_q;
    logic [1:0] audio_accept,audio_reply;
    logic audio_narrow_ready,oki_narrow_ready;
    logic audio_narrow_valid,oki_narrow_valid;
    wire [25:0] program_address=(program_master_i ? 26'h500000 : 26'h700000)+
                                {5'b0,program_word_address_i,1'b0};
    wire audio_live=!audio_reset_i && !audio_discard_q[0];
    wire oki_live=!audio_reset_i && !audio_discard_q[1];
    assign audio_req_ready_o=audio_live && audio_narrow_ready;
    assign oki_req_ready_o=oki_live && oki_narrow_ready;
    assign audio_rsp_valid_o=audio_live && audio_narrow_valid;
    assign oki_rsp_valid_o=oki_live && oki_narrow_valid;
    assign audio_accept={oki_req_i&&oki_req_ready_o,audio_req_i&&audio_req_ready_o};
    assign audio_reply={oki_narrow_valid,audio_narrow_valid};

    // Soft audio reset must not reset a shared cache lane while another owner
    // is active. Preserve the accepted read until its response is consumed,
    // suppress that old response, then admit a fresh request after drain.
    integer r;
    always_ff @(posedge clk_sys) begin
        if(cold_reset) begin
            audio_outstanding_q<=0;
            audio_discard_q<=0;
        end else begin
            for(r=0;r<2;r=r+1) begin
                if(audio_accept[r]) audio_outstanding_q[r]<=1;
                if(audio_reset_i && audio_outstanding_q[r]) audio_discard_q[r]<=1;
                if(audio_reply[r]) begin
                    audio_outstanding_q[r]<=0;
                    audio_discard_q[r]<=0;
                end
            end
        end
    end

    bigfight_graphics_rom_lanes graphics (
        .clk_sys,.cold_reset,
        .tile_gfx_req_o,.tile_gfx_ready_i,.tile_gfx_row_addr_o,
        .tile_gfx_rsp_valid_i,.tile_gfx_rsp_ready_o,.tile_gfx_rsp_data_i,
        .tile_clut_req_o,.tile_clut_ready_i,.tile_clut_row_addr_o,
        .tile_clut_rsp_valid_i,.tile_clut_rsp_ready_o,.tile_clut_rsp_data_i,
        .sprite_rom_req_o,.sprite_rom_ready_i,.sprite_rom_bank_o,
        .sprite_rom_byte_addr_o,.sprite_rom_valid_i,.sprite_rom_data_i,
        .sprite_clut_req_o,.sprite_clut_ready_i,.sprite_clut_color_o,
        .sprite_clut_valid_i,.sprite_clut_bytes_i,
        .lane_req(lane_req[6:0]),.lane_ready(lane_ready[6:0]),
        .lane_addresses(lane_addresses[0+:182]),.lane_valid(lane_valid[6:0]),
        .lane_rsp_ready(lane_rsp_ready[6:0]),.lane_data(lane_data[0+:448]));
    bigfight_rom_narrow64 #(.DATA_BITS(16)) program_port (
        .clk_sys,.cold_reset,.narrow_req_valid_i(program_req_i),
        .narrow_req_ready_o(program_req_ready_o),.narrow_req_byte_address_i(program_address),
        .narrow_rsp_valid_o(program_rsp_valid_o),.narrow_rsp_ready_i(program_rsp_ready_i),
        .narrow_rsp_data_o(program_rsp_data_o),
        .wide_req_valid_o(lane_req[7]),.wide_req_ready_i(lane_ready[7]),
        .wide_req_byte_address_o(lane_addresses[182+:26]),.wide_rsp_valid_i(lane_valid[7]),
        .wide_rsp_ready_o(lane_rsp_ready[7]),.wide_rsp_data_i(lane_data[448+:64]));
    bigfight_rom_narrow64 #(.DATA_BITS(8)) audio_port (
        .clk_sys,.cold_reset,.narrow_req_valid_i(audio_req_i&&audio_live),
        .narrow_req_ready_o(audio_narrow_ready),
        .narrow_req_byte_address_i(26'h080000+{10'b0,audio_byte_address_i}),
        .narrow_rsp_valid_o(audio_narrow_valid),.narrow_rsp_ready_i(1'b1),
        .narrow_rsp_data_o(audio_rsp_data_o),
        .wide_req_valid_o(lane_req[8]),.wide_req_ready_i(lane_ready[8]),
        .wide_req_byte_address_o(lane_addresses[208+:26]),.wide_rsp_valid_i(lane_valid[8]),
        .wide_rsp_ready_o(lane_rsp_ready[8]),.wide_rsp_data_i(lane_data[512+:64]));
    bigfight_rom_narrow64 #(.DATA_BITS(8)) oki_port (
        .clk_sys,.cold_reset,.narrow_req_valid_i(oki_req_i&&oki_live),
        .narrow_req_ready_o(oki_narrow_ready),
        .narrow_req_byte_address_i(26'h090000+{8'b0,oki_byte_address_i}),
        .narrow_rsp_valid_o(oki_narrow_valid),.narrow_rsp_ready_i(1'b1),
        .narrow_rsp_data_o(oki_rsp_data_o),
        .wide_req_valid_o(lane_req[9]),.wide_req_ready_i(lane_ready[9]),
        .wide_req_byte_address_o(lane_addresses[234+:26]),.wide_rsp_valid_i(lane_valid[9]),
        .wide_rsp_ready_o(lane_rsp_ready[9]),.wide_rsp_data_i(lane_data[576+:64]));
    // Client 4 holds the dense road-scene sprite working set between lines.
    bigfight_rom_fabric64 #(.CLIENTS(10), .WIDE_CLIENT(4), .WIDE_SET_BITS(10)) fabric (
        .clk_sys,.cold_reset,.client_req_valid_i(lane_req),.client_req_ready_o(lane_ready),
        .client_req_address_i(lane_addresses),.client_rsp_valid_o(lane_valid),
        .client_rsp_ready_i(lane_rsp_ready),.client_rsp_data_o(lane_data),
        .rom_req_valid_o(backend_req_valid),.rom_req_ready_i(backend_req_ready),
        .rom_req_address_o(backend_req_address),.rom_rsp_valid_i(backend_rsp_valid),
        .rom_rsp_ready_o(backend_rsp_ready),.rom_rsp_data_i(backend_rsp_data));
endmodule
