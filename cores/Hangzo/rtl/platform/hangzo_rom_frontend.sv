// SPDX-License-Identifier: GPL-3.0-only
// Logical packed-ROM service: main16, program8, PF0..3/sprite32, OKI0..1 byte.
// Addresses are mapped byte indices. Backend returns one aligned64 granule.
// No physical bank, SDRAM clock, burst configuration or deadline is implied.
module hangzo_rom_frontend(
    input wire clk,cold_reset,
    input wire [8:0] client_cs,
    input wire [9*26-1:0] client_byte_address,
    output wire [8:0] client_ready,
    output wire [9*32-1:0] client_data,
    output wire memory_request,
    input wire memory_accept,
    output wire [25:0] memory_byte_address,
    input wire memory_response,
    output wire memory_response_ready,
    input wire [63:0] memory_data
);
    wire [8:0] req_valid,req_ready,rsp_valid,rsp_ready;
    wire [9*26-1:0] req_addr;
    wire [9*64-1:0] rsp_data;
    genvar lane;
    generate for(lane=0;lane<9;lane=lane+1)begin: readers
        if(lane>=2 && lane<7)begin: level_reader
            localparam integer WIDTH=lane==0?16:lane==1?8:32;
            wire [WIDTH-1:0] result;
            assign client_data[lane*32+:32]={{(32-WIDTH){1'b0}},result};
            hangzo_rom_level_adapter #(.DATA_WIDTH(WIDTH),.CACHE_BITS(lane<6 ? 6 : 0)) bridge(
                .clk(clk),.cold_reset(cold_reset),.client_cs(client_cs[lane]),
                .client_byte_address(client_byte_address[lane*26+:26]),
                .client_ready(client_ready[lane]),.client_data(result),
                .request_valid(req_valid[lane]),.request_ready(req_ready[lane]),
                .request_address(req_addr[lane*26+:26]),
                .response_valid(rsp_valid[lane]),.response_ready(rsp_ready[lane]),
                .response_data(rsp_data[lane*64+:64]));
        end else begin: sample_reader
            localparam integer WIDTH=lane==0?16:8;
            wire [WIDTH-1:0] result;
            assign client_data[lane*32+:32]={{(32-WIDTH){1'b0}},result};
            hangzo_rom_byte_cache #(.DATA_WIDTH(WIDTH)) cache(
                .clk(clk),.cold_reset(cold_reset),.enable(client_cs[lane]),
                .byte_address(client_byte_address[lane*26+:26]),
                .ready(client_ready[lane]),.data(result),
                .request_valid(req_valid[lane]),.request_ready(req_ready[lane]),
                .request_address(req_addr[lane*26+:26]),
                .response_valid(rsp_valid[lane]),.response_ready(rsp_ready[lane]),
                .response_data(rsp_data[lane*64+:64]));
        end
    end endgenerate
    bigfight_rom_arb64 #(.CLIENTS(9)) arbiter(
        .clk_sys(clk),.cold_reset(cold_reset),
        .client_req_valid_i(req_valid),.client_req_ready_o(req_ready),
        .client_req_address_i(req_addr),.client_rsp_valid_o(rsp_valid),
        .client_rsp_ready_i(rsp_ready),.client_rsp_data_o(rsp_data),
        .rom_req_valid_o(memory_request),.rom_req_ready_i(memory_accept),
        .rom_req_address_o(memory_byte_address),.rom_rsp_valid_i(memory_response),
        .rom_rsp_ready_o(memory_response_ready),.rom_rsp_data_i(memory_data));
endmodule
