// SPDX-License-Identifier: GPL-2.0-or-later
// Complete-command retention for the non-stallable screen_rotate pulse writer.
module argus_rotate_ddr_queue #(
    parameter integer FIFO_DEPTH = 512,
    parameter integer USED_WIDTH = $clog2(FIFO_DEPTH + 3)
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire [7:0]            src_burstcnt,
    input  wire [28:0]           src_addr,
    input  wire [63:0]           src_din,
    input  wire [7:0]            src_be,
    input  wire                  src_we,
    input  wire                  src_rd,
    output wire                  src_busy,
    output wire                  src_accepted,
    input  wire                  dst_busy,
    output wire [7:0]            dst_burstcnt,
    output wire [28:0]           dst_addr,
    output wire [63:0]           dst_din,
    output wire [7:0]            dst_be,
    output wire                  dst_we,
    output wire                  dst_rd,
    output reg                   overflow = 1'b0,
    output wire                  fault_blank,
    output wire [USED_WIDTH-1:0] used
);
    localparam integer PTR_WIDTH = $clog2(FIFO_DEPTH);
    localparam integer RAM_COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);
    localparam integer TUPLE_WIDTH = 111;
    // Dedicated clocked read output permits M10K inference. The held output
    // head and RAM prefetch output are two additional command slots.
    (* ramstyle = "M10K" *) reg [TUPLE_WIDTH-1:0] fifo [0:FIFO_DEPTH-1];
    reg [TUPLE_WIDTH-1:0] ram_q;
    reg [TUPLE_WIDTH-1:0] head = {TUPLE_WIDTH{1'b0}};
    reg [PTR_WIDTH-1:0] read_ptr = {PTR_WIDTH{1'b0}};
    reg [PTR_WIDTH-1:0] write_ptr = {PTR_WIDTH{1'b0}};
    reg [RAM_COUNT_WIDTH-1:0] ram_count = {RAM_COUNT_WIDTH{1'b0}};
    reg head_valid = 1'b0;
    reg prefetch_valid = 1'b0;

    wire [TUPLE_WIDTH-1:0] src_tuple =
        {src_burstcnt, src_addr, src_din, src_be, src_we, src_rd};
    wire src_event = src_we || src_rd;
    wire dst_accepted = head_valid && !dst_busy;
    wire head_space = !head_valid || dst_accepted;
    wire take_prefetch = head_space && prefetch_valid;
    wire ram_fetch = !reset && (ram_count != 0) &&
                     (!prefetch_valid || take_prefetch);
    wire bypass_head = head_space && !prefetch_valid && (ram_count == 0);
    wire ram_space = (ram_count < FIFO_DEPTH) || ram_fetch;

    // BUSY describes input capacity, not downstream BUSY. Every asserted input
    // cycle is one producer event; a pulse while full cannot be retried here.
    assign src_busy = reset || overflow || (!bypass_head && !ram_space);
    assign src_accepted = src_event && !src_busy;
    wire ram_write = src_accepted && !bypass_head;
    assign used = ram_count + {{(USED_WIDTH-1){1'b0}}, head_valid} +
                  {{(USED_WIDTH-1){1'b0}}, prefetch_valid};
    assign fault_blank = overflow;
    assign {dst_burstcnt, dst_addr, dst_din, dst_be} = head[TUPLE_WIDTH-1:2];
    assign dst_we = head_valid && head[1];
    assign dst_rd = head_valid && head[0];

    // Nonblocking read-before-write semantics retain OLD_DATA on a full-ring
    // simultaneous pop/push. Do not add no_rw_check or an asynchronous read.
    always @(posedge clk) begin
        if (ram_fetch) ram_q <= fifo[read_ptr];
        if (ram_write) fifo[write_ptr] <= src_tuple;
    end

    always @(posedge clk) begin
        if (reset) begin
            read_ptr <= {PTR_WIDTH{1'b0}};
            write_ptr <= {PTR_WIDTH{1'b0}};
            ram_count <= {RAM_COUNT_WIDTH{1'b0}};
            prefetch_valid <= 1'b0;
            overflow <= 1'b0;
            // Already presented Avalon requests cannot be withdrawn under
            // waitrequest, even by reset. Discard only unpublished commands.
            if (!(head_valid && dst_busy)) begin
                head_valid <= 1'b0;
                head <= {TUPLE_WIDTH{1'b0}};
            end
        end else begin
            if (src_event && src_busy && !overflow) overflow <= 1'b1;
            if (ram_fetch) read_ptr <= read_ptr + 1'b1;
            if (ram_write) write_ptr <= write_ptr + 1'b1;
            case ({ram_write, ram_fetch})
                2'b10: ram_count <= ram_count + 1'b1;
                2'b01: ram_count <= ram_count - 1'b1;
                default: ;
            endcase
            case ({ram_fetch, take_prefetch})
                2'b10: prefetch_valid <= 1'b1;
                2'b01: prefetch_valid <= 1'b0;
                default: ;
            endcase
            if (take_prefetch) begin
                head <= ram_q;
                head_valid <= 1'b1;
            end else if (src_accepted && bypass_head) begin
                head <= src_tuple;
                head_valid <= 1'b1;
            end else if (dst_accepted) begin
                head_valid <= 1'b0;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
            $fatal(1, "argus_rotate_ddr_queue FIFO_DEPTH must be power-of-two >=2");
    end
`endif
endmodule
