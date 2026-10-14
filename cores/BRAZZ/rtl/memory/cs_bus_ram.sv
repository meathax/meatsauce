// SPDX-License-Identifier: GPL-3.0-or-later
// Synchronous byte-lane RAM slave. Reset cancels transactions, preserving RAM.
module cs_bus_ram #(
    parameter logic [31:0] BASE = 32'h02000000,
    parameter int WORD_ADDR_BITS = 8,
    parameter int ACCESS_CYCLES = 2
) (
    input  logic clk,
    input  logic reset,
    input  logic req_valid,
    output logic req_ready,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_data,
    input  logic [3:0] req_strb,
    input  logic req_write,
    output logic rsp_valid,
    output logic [31:0] rsp_data,
    output logic rsp_error
);
    localparam int WORDS = 1 << WORD_ADDR_BITS;
    localparam int COUNT_BITS = (ACCESS_CYCLES > 1) ? $clog2(ACCESS_CYCLES) : 1;
    logic [31:0] ram [0:WORDS-1];
    logic busy;
    logic [COUNT_BITS-1:0] remaining;
    logic [WORD_ADDR_BITS-1:0] index;
    logic [31:0] data;
    logic [3:0] strb;
    logic write_op, error;

    assign req_ready = !busy && !reset;

    always_ff @(posedge clk) begin
        rsp_valid <= 1'b0;
        if (reset) begin
            busy <= 1'b0;
            remaining <= '0;
            index <= '0;
            data <= '0;
            strb <= '0;
            write_op <= 1'b0;
            error <= 1'b0;
            rsp_data <= '0;
            rsp_error <= 1'b0;
        end else if (!busy) begin
            if (req_valid) begin
                busy <= 1'b1;
                remaining <= COUNT_BITS'(ACCESS_CYCLES - 1);
                index <= WORD_ADDR_BITS'((req_addr - BASE) >> 2);
                data <= req_data;
                strb <= req_strb;
                write_op <= req_write;
                error <= (req_addr[1:0] != 0) || (req_addr < BASE) ||
                         ((req_addr - BASE) >= 32'(WORDS * 4));
            end
        end else if (remaining != 0) begin
            remaining <= remaining - 1'b1;
        end else begin
            busy <= 1'b0;
            rsp_valid <= 1'b1;
            rsp_error <= error;
            rsp_data <= error ? 32'hffffffff : ram[index];
            if (!error && write_op) begin
                for (int lane = 0; lane < 4; lane++)
                    if (strb[lane]) ram[index][lane*8 +: 8] <= data[lane*8 +: 8];
            end
        end
    end
endmodule
