// SPDX-License-Identifier: GPL-3.0-or-later
// Byte/halfword/word CPU accesses on the aligned 32-bit board bus.
// Unaligned accesses split only when they cross a word boundary.
// command_size 3 (CPU only) is a paired instruction fetch: it returns the upper
// halfword of the most recent bus reply without a request. The CPU issues it
// only for the sequential successor of an instruction fetched from an aligned
// word with no access in between, i.e. the other half of that same reply.
// PASS_THROUGH=1 presents the first bus request in the same clock the command
// arrives (no REQUEST register stage); a request not accepted then waits in
// REQUEST as before. It also accepts the next command in the clock a final
// reply is consumed (command_ready covers that clock), so back-to-back CPU
// accesses need no idle clock. The caller must hold a stable payload while
// command_valid.
module se3208_bus_access #(parameter bit BYPASS_FINAL_REPLY=1'b1, parameter bit PASS_THROUGH=1'b0) (
    input logic clk, reset,
    input logic command_valid,
    output logic command_ready,
    input logic [31:0] command_address, command_data,
    input logic [1:0] command_size,
    input logic command_write,
    output logic result_valid,
    input logic result_ready,
    output logic [31:0] result_data,
    output logic result_error,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error
);
    typedef enum logic [1:0] {IDLE, REQUEST, WAIT_RESPONSE, RESULT} state_t;
    state_t state;
    logic [31:0] address, data, first_read;
    logic [1:0] size;
    logic write_access, second;
    logic terminal_reply;
    logic [31:0] held_result_data;
    logic held_result_error;
    logic [7:0] byte_mask, request_mask;
    logic [63:0] shifted_data, joined_read;
    logic [15:0] pair_half;
    // The registered access's lane mask drives reply handling; the request
    // payload comes from the command whenever a new command can start.
    assign byte_mask = ((size == 0) ? 8'h01 : (size[0]) ? 8'h03 : 8'h0f) << address[1:0];
    // The same-clock (bypass) reply is limited to single-word accesses at an
    // even address, whose result is the reply or its upper half (a 2:1 select).
    // Odd-address and word-crossing results are aligned into RESULT first (one
    // clock later); this keeps the byte shifter/join out of the CPU's
    // reply -> decode -> operand path.
    assign terminal_reply = BYPASS_FINAL_REPLY && state == WAIT_RESPONSE && rsp_valid &&
                            (rsp_error || (!second && byte_mask[7:4] == 0 && !address[0]));
    wire chain = PASS_THROUGH && result_ready && (terminal_reply || state == RESULT);
    wire from_command = PASS_THROUGH && (state == IDLE || chain);
    wire start = command_valid && (state == IDLE || chain);
    wire pass = from_command && command_valid && command_size != 2'd3;
    wire [31:0] cur_address = from_command ? command_address : address;
    wire [31:0] cur_data = from_command ? command_data : data;
    wire [1:0] cur_size = from_command ? command_size : size;
    wire cur_second = !from_command && second; // a new command starts with its first word
    always_comb begin
        request_mask = ((cur_size == 0) ? 8'h01 : (cur_size[0]) ? 8'h03 : 8'h0f) << cur_address[1:0];
        shifted_data = {32'b0,cur_data} << {cur_address[1:0],3'b000};
        joined_read = second ? {rsp_data,first_read} : {32'b0,rsp_data};
        command_ready = state == IDLE || chain;
        // Consume a final bus reply on this edge when the CPU is enabled.
        // Otherwise retain it in RESULT, independently of CPU clock enable.
        result_valid = state == RESULT || terminal_reply;
        result_data = terminal_reply && !rsp_error ?
                      (address[1] ? {16'b0,rsp_data[31:16]} : rsp_data) : held_result_data;
        result_error = terminal_reply ? rsp_error : held_result_error;
        req_valid = state == REQUEST || pass;
        // Only the registered second half of a split access adds 4.
        req_address = cur_second ? {address[31:2],2'b00} + 32'd4 : {cur_address[31:2],2'b00};
        req_strobe = cur_second ? request_mask[7:4] : request_mask[3:0];
        req_data = cur_second ? shifted_data[63:32] : shifted_data[31:0];
        req_write = from_command ? command_write : write_access;
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            held_result_data <= 0;
            held_result_error <= 0;
            address <= 0; data <= 0; first_read <= 0;
            size <= 0; write_access <= 0; second <= 0; pair_half <= 0;
        end else begin
            case (state)
                IDLE: begin end
                REQUEST: if (req_ready) state <= WAIT_RESPONSE;
                WAIT_RESPONSE: if (rsp_valid) begin
                    pair_half <= rsp_data[31:16];
                    if (rsp_error) begin
                        held_result_error <= 1;
                        state <= (terminal_reply && result_ready) ? IDLE : RESULT;
                    end
                    else if (!second && byte_mask[7:4] != 0) begin
                        first_read <= rsp_data; second <= 1; state <= REQUEST;
                    end else begin
                        held_result_data <= 32'(joined_read >> {address[1:0],3'b000});
                        held_result_error <= 0;
                        state <= (terminal_reply && result_ready) ? IDLE : RESULT;
                    end
                end
                RESULT: if (result_ready) state <= IDLE;
            endcase
            // A new command (from IDLE, or chained on a consumed final reply)
            // overrides the reply handling's next state above.
            if (start) begin
                address <= command_address; data <= command_data;
                size <= command_size; write_access <= command_write;
                second <= 0; held_result_error <= 0;
                if (command_size == 2'd3) begin
                    held_result_data <= {16'b0,pair_half};
                    state <= RESULT;
                end else state <= (pass && req_ready) ? WAIT_RESPONSE : REQUEST;
            end
        end
    end
endmodule
