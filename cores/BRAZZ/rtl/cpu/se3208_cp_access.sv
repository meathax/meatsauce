// SPDX-License-Identifier: GPL-3.0-or-later
// One outstanding coprocessor transfer. Transport runs at clk; CPU ce only
// governs command/result handoff. Hold replies until the CPU consumes them.
module se3208_cp_access (
    input logic clk, reset,
    input logic command_valid, output logic command_ready,
    input logic command_write,
    input logic [1:0] command_id,
    input logic [2:0] command_register,
    input logic [31:0] command_data,
    output logic result_valid, input logic result_ready,
    output logic [31:0] result_data, output logic result_error,
    output logic cp_req_valid, input logic cp_req_ready,
    output logic cp_req_write,
    output logic [1:0] cp_req_id,
    output logic [2:0] cp_req_register,
    output logic [31:0] cp_req_data,
    input logic cp_rsp_valid, output logic cp_rsp_ready,
    input logic [31:0] cp_rsp_data, input logic cp_rsp_error
);
    typedef enum logic [1:0] {IDLE, REQUEST, RESPONSE, RESULT} state_t;
    state_t state;
    assign command_ready = state == IDLE;
    assign cp_req_valid = state == REQUEST;
    assign cp_rsp_ready = state == RESPONSE || (state == REQUEST && cp_req_ready);
    assign result_valid = state == RESULT;
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            cp_req_write <= 0; cp_req_id <= 0; cp_req_register <= 0; cp_req_data <= 0;
            result_data <= 0; result_error <= 0;
        end else case (state)
            IDLE: if (command_valid) begin
                cp_req_write <= command_write;
                cp_req_id <= command_id; cp_req_register <= command_register;
                cp_req_data <= command_data;
                state <= REQUEST;
            end
            REQUEST: if (cp_req_ready) begin
                if (cp_rsp_valid) begin
                    result_data <= cp_rsp_data; result_error <= cp_rsp_error;
                    state <= RESULT;
                end else state <= RESPONSE;
            end
            RESPONSE: if (cp_rsp_valid) begin
                result_data <= cp_rsp_data; result_error <= cp_rsp_error;
                state <= RESULT;
            end
            RESULT: if (result_ready) state <= IDLE;
        endcase
    end
endmodule
