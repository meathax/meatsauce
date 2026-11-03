`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-only
// Big Fight shared immutable-ROM read arbiter.
// Round-robin selection and captured service ownership follow the pinned
// Fuuki MiSTer SDRAM arbiter pattern; transaction signaling is adapted to
// held ready/valid requests and replies.
module bigfight_rom_arb64 #(
    parameter integer CLIENTS = 8
) (
    input  logic                         clk_sys,
    input  logic                         cold_reset,

    input  logic [CLIENTS-1:0]           client_req_valid_i,
    output logic [CLIENTS-1:0]           client_req_ready_o,
    input  logic [CLIENTS*26-1:0]         client_req_address_i,
    output logic [CLIENTS-1:0]           client_rsp_valid_o,
    input  logic [CLIENTS-1:0]           client_rsp_ready_i,
    output logic [CLIENTS*64-1:0]         client_rsp_data_o,

    output logic                         rom_req_valid_o,
    input  logic                         rom_req_ready_i,
    output logic [25:0]                  rom_req_address_o,
    input  logic                         rom_rsp_valid_i,
    output logic                         rom_rsp_ready_o,
    input  logic [63:0]                  rom_rsp_data_i
);
    localparam integer OWNER_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS);
    localparam logic [1:0] ST_IDLE       = 2'd0;
    localparam logic [1:0] ST_ROM_REQ    = 2'd1;
    localparam logic [1:0] ST_ROM_RSP    = 2'd2;
    localparam logic [1:0] ST_CLIENT_RSP = 2'd3;

    logic [1:0] state_q;
    logic [OWNER_W-1:0] rr_start_q;
    logic [OWNER_W-1:0] owner_q;
    logic [25:0] address_q;
    logic [63:0] response_data_q;

    logic pick_valid;
    logic [OWNER_W-1:0] pick;
    integer scan_offset;
    integer candidate;

    // Search from the rotating start point. At most one subtract is needed
    // because scan_offset and rr_start_q are each less than CLIENTS.
    always_comb begin
        pick_valid = 1'b0;
        pick = '0;
        candidate = 0;
        for (scan_offset = 0; scan_offset < CLIENTS; scan_offset = scan_offset + 1) begin
            candidate = rr_start_q + scan_offset;
            if (candidate >= CLIENTS)
                candidate = candidate - CLIENTS;
            if (!pick_valid && client_req_valid_i[candidate]) begin
                pick_valid = 1'b1;
                pick = candidate;
            end
        end
    end

    always_comb begin
        client_req_ready_o = '0;
        client_rsp_valid_o = '0;
        client_rsp_data_o = '0;
        rom_req_valid_o = 1'b0;
        rom_req_address_o = address_q;
        rom_rsp_ready_o = 1'b0;

        if (!cold_reset) begin
            case (state_q)
                ST_IDLE: begin
                    if (pick_valid)
                        client_req_ready_o[pick] = 1'b1;
                end
                ST_ROM_REQ: begin
                    rom_req_valid_o = 1'b1;
                end
                ST_ROM_RSP: begin
                    rom_rsp_ready_o = 1'b1;
                end
                ST_CLIENT_RSP: begin
                    client_rsp_valid_o[owner_q] = 1'b1;
                    client_rsp_data_o[64*owner_q +: 64] = response_data_q;
                end
                default: begin
                    // Sequential recovery returns an illegal state to idle.
                end
            endcase
        end
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            rr_start_q <= '0;
            owner_q <= '0;
            address_q <= 26'd0;
            response_data_q <= 64'd0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (pick_valid && client_req_valid_i[pick] && client_req_ready_o[pick]) begin
                        owner_q <= pick;
                        address_q <= client_req_address_i[26*pick +: 26];
                        state_q <= ST_ROM_REQ;
                    end
                end
                ST_ROM_REQ: begin
                    if (rom_req_valid_o && rom_req_ready_i)
                        state_q <= ST_ROM_RSP;
                end
                ST_ROM_RSP: begin
                    if (rom_rsp_valid_i && rom_rsp_ready_o) begin
                        response_data_q <= rom_rsp_data_i;
                        state_q <= ST_CLIENT_RSP;
                    end
                end
                ST_CLIENT_RSP: begin
                    if (client_rsp_valid_o[owner_q] && client_rsp_ready_i[owner_q]) begin
                        rr_start_q <= (owner_q == CLIENTS-1) ? '0 : owner_q + 1'b1;
                        state_q <= ST_IDLE;
                    end
                end
                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
