// SPDX-License-Identifier: GPL-3.0-only
// Isolated same-port latency candidate for bigfight_rom_group64.
// Compile exactly one implementation of that module at a time.
`timescale 1ns/1ps
module bigfight_rom_group64 #(parameter integer WAYS=1) (
    input logic clk_sys,
    input logic cold_reset,
    input logic req_valid_i,
    output logic req_ready_o,
    input logic [WAYS*26-1:0] req_addresses_i,
    output logic rsp_valid_o,
    input logic rsp_ready_i,
    output logic [WAYS*64-1:0] rsp_data_o,
    output logic [WAYS-1:0] wide_req_valid_o,
    input logic [WAYS-1:0] wide_req_ready_i,
    output logic [WAYS*26-1:0] wide_req_addresses_o,
    input logic [WAYS-1:0] wide_rsp_valid_i,
    output logic [WAYS-1:0] wide_rsp_ready_o,
    input logic [WAYS*64-1:0] wide_rsp_data_i
);
    localparam logic [1:0] IDLE = 2'd0;
    localparam logic [1:0] WAIT_REPLIES = 2'd1;
    localparam logic [1:0] HOLD_REPLY = 2'd2;

    logic [1:0] state;
    logic [WAYS-1:0] pending;
    logic [WAYS-1:0] accepted;
    logic [WAYS-1:0] received;
    logic [WAYS-1:0] received_now;
    logic [WAYS*26-1:0] held_addresses;
    logic [WAYS*64-1:0] held_reply;
    logic [WAYS*64-1:0] merged_reply;
    integer lane_comb;
    integer lane_seq;

    assign req_ready_o = !cold_reset && state == IDLE;
    assign wide_req_valid_o = cold_reset ? '0 :
        (state == IDLE ? {WAYS{req_valid_i && req_ready_o}} :
         (state == WAIT_REPLIES ? pending : '0));
    assign wide_req_addresses_o =
        (state == IDLE) ? req_addresses_i : held_addresses;
    assign wide_rsp_ready_o = (!cold_reset && state == WAIT_REPLIES) ?
        (accepted & ~received) : '0;

    always_comb begin
        lane_comb = 0;
        received_now = received;
        merged_reply = held_reply;
        if (!cold_reset && state == WAIT_REPLIES) begin
            for (lane_comb = 0; lane_comb < WAYS; lane_comb = lane_comb + 1) begin
                if (received[lane_comb]) begin
                    merged_reply[64*lane_comb +: 64] = held_reply[64*lane_comb +: 64];
                end else if (wide_rsp_valid_i[lane_comb] && wide_rsp_ready_o[lane_comb]) begin
                    received_now[lane_comb] = 1'b1;
                    merged_reply[64*lane_comb +: 64] = wide_rsp_data_i[64*lane_comb +: 64];
                end
            end
        end
    end

    assign rsp_valid_o = !cold_reset &&
        ((state == HOLD_REPLY) || (state == WAIT_REPLIES && (&received_now)));
    assign rsp_data_o = (state == HOLD_REPLY) ? held_reply : merged_reply;

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state <= IDLE;
            pending <= '0;
            accepted <= '0;
            received <= '0;
            held_addresses <= '0;
            held_reply <= '0;
        end else begin
            case (state)
                IDLE: if (req_valid_i && req_ready_o) begin
                    held_addresses <= req_addresses_i;
                    // Requests accepted on the native acceptance edge are
                    // already complete; only stalled lanes remain pending.
                    pending <= ~wide_req_ready_i;
                    accepted <= wide_req_ready_i;
                    received <= '0;
                    state <= WAIT_REPLIES;
                end

                WAIT_REPLIES: begin
                    for (lane_seq = 0; lane_seq < WAYS; lane_seq = lane_seq + 1) begin
                        if (wide_req_valid_o[lane_seq] && wide_req_ready_i[lane_seq]) begin
                            pending[lane_seq] <= 1'b0;
                            accepted[lane_seq] <= 1'b1;
                        end
                        if (wide_rsp_valid_i[lane_seq] && wide_rsp_ready_o[lane_seq]) begin
                            received[lane_seq] <= 1'b1;
                            held_reply[64*lane_seq +: 64] <= wide_rsp_data_i[64*lane_seq +: 64];
                        end
                    end

                    // A final backend beat can complete the native transfer
                    // on this same edge. If the native side stalls, the same
                    // merged payload is captured for HOLD_REPLY instead.
                    if (&received_now) begin
                        if (rsp_ready_i)
                            state <= IDLE;
                        else
                            state <= HOLD_REPLY;
                    end
                end

                HOLD_REPLY: if (rsp_ready_i)
                    state <= IDLE;

                default: state <= IDLE;
            endcase
        end
    end
endmodule
