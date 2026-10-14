// SPDX-License-Identifier: GPL-3.0-or-later
// Two VRender0 DMA channels. Transfers use genuine stalled board-bus accesses,
// not the reference emulator's instantaneous memcpy. Repeat modes are explicit
// unsupported errors pending board evidence; single-transfer modes are complete.
module vr0_dma (
    input logic clk, reset,
    input logic reg_valid,
    output logic reg_ready,
    input logic [4:0] reg_address,
    input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,
    input logic reg_write,
    output logic reg_rsp_valid,
    output logic [31:0] reg_rsp_data,
    output logic reg_rsp_error,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error,
    output logic [1:0] completion,
    output logic busy, fault,
    output logic fault_channel,
    output logic [31:0] fault_address,
    output logic [31:0] remaining
);
    typedef enum logic [2:0] {IDLE, READ_START, READ_WAIT, WRITE_START, WRITE_WAIT, FAILED} state_t;
    state_t state;
    logic [31:0] control [0:1], source [0:1], destination [0:1], count [0:1];
    logic [1:0] pending;
    logic active_channel;
    logic [31:0] current_source, current_destination, transfer_data, source_delta, destination_delta;
    logic [1:0] width;
    logic [31:0] mask, merged, step_bytes;
    logic command_ready, result_valid, result_error;
    logic [31:0] result_data;
    logic register_channel, selected_channel, trigger, valid_register;
    always_comb begin
        register_channel = reg_address[4];
        selected_channel = pending[0] ? 1'b0 : 1'b1;
        mask = {{8{reg_strobe[3]}},{8{reg_strobe[2]}},{8{reg_strobe[1]}},{8{reg_strobe[0]}}};
        merged = (control[register_channel] & ~mask) | (reg_data & mask);
        trigger = reg_valid && reg_write && reg_address[3:0] == 0 && !control[register_channel][10] && merged[10];
        valid_register = reg_address[1:0] == 0;
        if (trigger && (merged[7:6] != 0 || (state != IDLE && active_channel == register_channel))) valid_register = 0;
        reg_ready = 1;
        busy = state != IDLE || pending != 0;
        step_bytes = control[selected_channel][1] ? 32'd4 : (control[selected_channel][0] ? 32'd2 : 32'd1);
    end
    se3208_bus_access access_unit (.clk, .reset,
        .command_valid(state == READ_START || state == WRITE_START), .command_ready,
        .command_address(state == WRITE_START ? current_destination : current_source),
        .command_data(transfer_data), .command_size(width), .command_write(state == WRITE_START),
        .result_valid, .result_ready(state == READ_WAIT || state == WRITE_WAIT),
        .result_data, .result_error, .req_valid, .req_ready, .req_address,
        .req_data, .req_strobe, .req_write, .rsp_valid, .rsp_data, .rsp_error);
    always_ff @(posedge clk) begin
        completion <= 0;
        if (reset) begin
            state <= IDLE; pending <= 0; active_channel <= 0;
            current_source <= 0; current_destination <= 0; transfer_data <= 0;
            source_delta <= 0; destination_delta <= 0; width <= 0; remaining <= 0;
            fault <= 0; fault_channel <= 0; fault_address <= 0;
            reg_rsp_valid <= 0; reg_rsp_data <= 0; reg_rsp_error <= 0;
            for (int i=0;i<2;i=i+1) begin control[i] <= 0; source[i] <= 0; destination[i] <= 0; count[i] <= 0; end
        end else begin
            reg_rsp_valid <= reg_valid;
            if (reg_valid) begin
                reg_rsp_error <= !valid_register;
                case (reg_address[3:2])
                    0: reg_rsp_data <= control[register_channel];
                    1: reg_rsp_data <= source[register_channel];
                    2: reg_rsp_data <= destination[register_channel];
                    3: reg_rsp_data <= count[register_channel];
                endcase
                if (reg_write && valid_register) case (reg_address[3:2])
                    0: begin
                        control[register_channel] <= merged;
                        if (trigger) pending[register_channel] <= 1;
                    end
                    1: source[register_channel] <= (source[register_channel] & ~mask) | (reg_data & mask);
                    2: destination[register_channel] <= (destination[register_channel] & ~mask) | (reg_data & mask);
                    3: count[register_channel] <= ((count[register_channel] & ~mask) | (reg_data & mask)) & 32'h00ffffff; // DMATCx is 24 bits (MAME master)
                endcase
            end
            case (state)
                IDLE: if (pending != 0) begin
                    active_channel <= selected_channel;
                    pending[selected_channel] <= 0;
                    current_source <= source[selected_channel];
                    current_destination <= destination[selected_channel];
                    source_delta <= control[selected_channel][5] ? 32'b0 : (control[selected_channel][4] ? -step_bytes : step_bytes);
                    destination_delta <= control[selected_channel][3] ? 32'b0 : (control[selected_channel][2] ? -step_bytes : step_bytes);
                    width <= control[selected_channel][1] ? 2'd2 : {1'b0,control[selected_channel][0]};
                    remaining <= count[selected_channel];
                    if (count[selected_channel] == 0) begin
                        control[selected_channel][10] <= 0;
                        completion[selected_channel] <= 1;
                    end else state <= READ_START;
                end
                READ_START: if (command_ready) state <= READ_WAIT;
                READ_WAIT: if (result_valid) begin
                    if (result_error) begin
                        fault <= 1; fault_channel <= active_channel; fault_address <= current_source;
                        state <= FAILED;
                    end else begin transfer_data <= result_data; state <= WRITE_START; end
                end
                WRITE_START: if (command_ready) state <= WRITE_WAIT;
                WRITE_WAIT: if (result_valid) begin
                    if (result_error) begin
                        fault <= 1; fault_channel <= active_channel; fault_address <= current_destination;
                        state <= FAILED;
                    end else begin
                        remaining <= remaining - 1'b1;
                        current_source <= current_source + source_delta;
                        current_destination <= current_destination + destination_delta;
                        if (remaining == 1) begin
                            control[active_channel][10] <= 0;
                            count[active_channel] <= 0;
                            completion[active_channel] <= 1;
                            state <= IDLE;
                        end else state <= READ_START;
                    end
                end
                FAILED: begin end
                default: state <= FAILED;
            endcase
        end
    end
endmodule
