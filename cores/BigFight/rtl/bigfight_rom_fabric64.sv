`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-only
// One independent immutable-ROM granule cache per client, sharing one
// captured-owner 64-bit request arbiter and one backend service.
module bigfight_rom_fabric64 #(
    parameter integer CLIENTS = 10,
    // Client whose cache uses WIDE_SET_BITS sets (-1: none); others keep 6.
    parameter integer WIDE_CLIENT = -1,
    parameter integer WIDE_SET_BITS = 7
) (
    input  logic                         clk_sys,
    input  logic                         cold_reset,

    input  logic [CLIENTS-1:0]           client_req_valid_i,
    output logic [CLIENTS-1:0]           client_req_ready_o,
    input  logic [CLIENTS*26-1:0]        client_req_address_i,
    output logic [CLIENTS-1:0]           client_rsp_valid_o,
    input  logic [CLIENTS-1:0]           client_rsp_ready_i,
    output logic [CLIENTS*64-1:0]        client_rsp_data_o,

    output logic                         rom_req_valid_o,
    input  logic                         rom_req_ready_i,
    output logic [25:0]                  rom_req_address_o,
    input  logic                         rom_rsp_valid_i,
    output logic                         rom_rsp_ready_o,
    input  logic [63:0]                  rom_rsp_data_i
);
    logic [CLIENTS-1:0] cache_rom_req_valid;
    logic [CLIENTS-1:0] cache_rom_req_ready;
    logic [CLIENTS*26-1:0] cache_rom_req_address;
    logic [CLIENTS-1:0] cache_rom_rsp_valid;
    logic [CLIENTS-1:0] cache_rom_rsp_ready;
    logic [CLIENTS*64-1:0] cache_rom_rsp_data;

    genvar lane;
    generate
        for (lane = 0; lane < CLIENTS; lane = lane + 1) begin : g_client_cache
            bigfight_rom_cache64 #(.SET_BITS((lane == WIDE_CLIENT) ? WIDE_SET_BITS : 6)) cache_i (
                .clk_sys,
                .cold_reset,
                .client_req_valid_i(client_req_valid_i[lane]),
                .client_req_ready_o(client_req_ready_o[lane]),
                .client_req_address_i(client_req_address_i[26*lane +: 26]),
                .client_rsp_valid_o(client_rsp_valid_o[lane]),
                .client_rsp_ready_i(client_rsp_ready_i[lane]),
                .client_rsp_data_o(client_rsp_data_o[64*lane +: 64]),
                .rom_req_valid_o(cache_rom_req_valid[lane]),
                .rom_req_ready_i(cache_rom_req_ready[lane]),
                .rom_req_address_o(cache_rom_req_address[26*lane +: 26]),
                .rom_rsp_valid_i(cache_rom_rsp_valid[lane]),
                .rom_rsp_ready_o(cache_rom_rsp_ready[lane]),
                .rom_rsp_data_i(cache_rom_rsp_data[64*lane +: 64])
            );
        end
    endgenerate

    bigfight_rom_arb64 #(.CLIENTS(CLIENTS)) arbiter_i (
        .clk_sys,
        .cold_reset,
        .client_req_valid_i(cache_rom_req_valid),
        .client_req_ready_o(cache_rom_req_ready),
        .client_req_address_i(cache_rom_req_address),
        .client_rsp_valid_o(cache_rom_rsp_valid),
        .client_rsp_ready_i(cache_rom_rsp_ready),
        .client_rsp_data_o(cache_rom_rsp_data),
        .rom_req_valid_o,
        .rom_req_ready_i,
        .rom_req_address_o,
        .rom_rsp_valid_i,
        .rom_rsp_ready_o,
        .rom_rsp_data_i
    );
endmodule
