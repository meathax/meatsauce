// SPDX-License-Identifier: GPL-3.0-only
// Isolated lower-latency candidate for bigfight_rom_arb64.
// Compile this file instead of rtl/bigfight_rom_arb64.sv, never with it.
// cold_reset must also cancel/flush the shared ROM backend transaction.
`timescale 1ns/1ps
module bigfight_rom_arb64 #(
    parameter integer CLIENTS = 8
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
    localparam integer OWNER_W = (CLIENTS <= 1) ? 1 : $clog2(CLIENTS);
    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_SEND = 2'd1;
    localparam logic [1:0] ST_WAIT = 2'd2;
    localparam logic [1:0] ST_HOLD = 2'd3;

    logic [1:0] state_q;
    logic [OWNER_W-1:0] rr_start_q;
    logic [OWNER_W-1:0] owner_q;
    logic [25:0] address_q;
    logic [63:0] response_data_q;

    logic [1:0] sprite_credits_q;
    logic owner_priority_q;
    wire priority_pick = (sprite_credits_q != 0) && client_req_valid_i[4];
    logic pick_valid;
    logic [OWNER_W-1:0] pick;
    integer scan_offset;
    integer candidate;

    // 2026-10-23 timing repair: the same rotating priority (first requester at
    // or after rr_start_q) as a one-hot grant plus AND-OR address mux, instead
    // of a sequential scan and a multiplied part-select index.
    logic [CLIENTS-1:0] grant;
    logic [25:0] pick_address;
    always_comb begin
        integer c, d;
        logic blocked;
        grant = '0;
        pick_valid = 1'b0;
        pick = '0;
        pick_address = '0;
        if (priority_pick) begin
            // Keep the dense sprite lane on a direct address path; do not
            // route its cache miss through the round-robin grant/address tree.
            grant[4] = 1'b1;
            pick_valid = 1'b1;
            pick = OWNER_W'(4);
            pick_address = client_req_address_i[26*4 +: 26];
        end else begin
            for (c = 0; c < CLIENTS; c = c + 1) begin
                // Client d precedes c when it lies in [rr_start_q, c) cyclically.
                blocked = 1'b0;
                for (d = 0; d < CLIENTS; d = d + 1)
                    if (d != c && client_req_valid_i[d] &&
                        ((rr_start_q <= c) ? (d >= rr_start_q && d < c)
                                           : (d >= rr_start_q || d < c)))
                        blocked = 1'b1;
                grant[c] = client_req_valid_i[c] && !blocked;
            end
            pick_valid = |grant;
            for (c = 0; c < CLIENTS; c = c + 1)
                if (grant[c]) begin
                    pick = pick | OWNER_W'(c);
                    pick_address = pick_address | client_req_address_i[26*c +: 26];
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
                    if (pick_valid) begin
                        // Accept/capture one client even if the ROM is busy.
                        // If it is ready now, both request handshakes share this edge.
                        client_req_ready_o[pick] = 1'b1;
                        rom_req_valid_o = 1'b1;
                        rom_req_address_o = pick_address;
                    end
                end
                ST_SEND: begin
                    rom_req_valid_o = 1'b1;
                end
                ST_WAIT: begin
                    // Keep backend ready high. A ready owner consumes the same
                    // response edge; otherwise the accepted response is saved.
                    rom_rsp_ready_o = 1'b1;
                    client_rsp_valid_o[owner_q] = rom_rsp_valid_i;
                    client_rsp_data_o[64*owner_q +: 64] = rom_rsp_data_i;
                end
                ST_HOLD: begin
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
            sprite_credits_q <= 2'd2;owner_priority_q <= 1'b0;
            owner_q <= '0;
            address_q <= 26'd0;
            response_data_q <= 64'd0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (pick_valid && client_req_valid_i[pick] && client_req_ready_o[pick]) begin
                        owner_q <= pick;owner_priority_q <= priority_pick;
                        address_q <= pick_address;
                        if (rom_req_valid_o && rom_req_ready_i)
                            state_q <= ST_WAIT;
                        else
                            state_q <= ST_SEND;
                    end
                end
                ST_SEND: begin
                    if (rom_req_valid_o && rom_req_ready_i)
                        state_q <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (rom_rsp_valid_i && rom_rsp_ready_o) begin
                        if (client_rsp_ready_i[owner_q]) begin
                            if(!owner_priority_q)rr_start_q <= (owner_q == CLIENTS-1) ? '0 : owner_q + 1'b1;
                        sprite_credits_q <= owner_priority_q ? sprite_credits_q - 1'b1 : 2'd2;
                            state_q <= ST_IDLE;
                        end else begin
                            response_data_q <= rom_rsp_data_i;
                            state_q <= ST_HOLD;
                        end
                    end
                end
                ST_HOLD: begin
                    if (client_rsp_valid_o[owner_q] && client_rsp_ready_i[owner_q]) begin
                        if(!owner_priority_q)rr_start_q <= (owner_q == CLIENTS-1) ? '0 : owner_q + 1'b1;
                        sprite_credits_q <= owner_priority_q ? sprite_credits_q - 1'b1 : 2'd2;
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
