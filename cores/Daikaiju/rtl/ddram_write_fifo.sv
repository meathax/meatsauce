// Retain the stock screen_rotate write pulses until the MiSTer DDRAM
// interface accepts them. The producer cannot be backpressured by DDRAM_BUSY.
module daikaiju_ddram_write_fifo #(
    parameter integer DEPTH = 64,
    parameter integer PTR_W = $clog2(DEPTH)
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic [28:0] in_address,
    input  logic [63:0] in_data,
    input  logic [7:0]  in_byteenable,
    input  logic [7:0]  in_burstcount,
    input  logic        ddram_busy,
    output logic [28:0] ddram_address,
    output logic [63:0] ddram_data,
    output logic [7:0]  ddram_byteenable,
    output logic [7:0]  ddram_burstcount,
    output logic        ddram_write,
    output logic        overflow,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    localparam integer TUPLE_W = 109;

    // MLAB with asynchronous read feeding the head register. Every case where
    // read_address equals wr_ptr during a push (count 0, or count 1 with
    // pop+push) loads head_data from the input instead, so no_rw_check holds.
    (* ramstyle = "MLAB, no_rw_check" *) logic [TUPLE_W-1:0] fifo_mem [0:DEPTH-1];
    logic [PTR_W-1:0] rd_ptr, wr_ptr;
    logic [TUPLE_W-1:0] head_data;
    logic head_valid;
    logic [COUNT_W-1:0] count;
    logic [PTR_W-1:0] read_address;
    logic pop, push, room;

    assign occupancy = count;
    assign read_address = pop ? rd_ptr + {{(PTR_W-1){1'b0}},1'b1} : rd_ptr;
    assign ddram_write = head_valid && (count != 0) && !ddram_busy;
    assign ddram_address = head_data[108:80];
    assign ddram_data = head_data[79:16];
    assign ddram_byteenable = head_data[15:8];
    assign ddram_burstcount = head_data[7:0];
    assign pop = ddram_write;
    assign room = (count < DEPTH) || pop;
    assign push = in_valid && room;

    always_ff @(posedge clk) begin
        if (push)
            fifo_mem[wr_ptr] <= {in_address, in_data, in_byteenable, in_burstcount};

        // Advance the synchronous read address with the popped head so the
        // next queued tuple is available without an output bubble.
        if (!reset && (count != 0) && !((count == 1) && pop && push))
            head_data <= fifo_mem[read_address];
        else if (!reset && (count == 0) && push)
            head_data <= {in_address, in_data, in_byteenable, in_burstcount};
        else if (!reset && (count == 1) && pop && push)
            head_data <= {in_address, in_data, in_byteenable, in_burstcount};

        if (reset) begin
            rd_ptr <= '0;
            wr_ptr <= '0;
            count <= '0;
            head_valid <= 1'b0;
            overflow <= 1'b0;
        end else begin
            if (push) wr_ptr <= wr_ptr + 1'b1;
            if (pop)  rd_ptr <= rd_ptr + 1'b1;

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (in_valid && !room) overflow <= 1'b1;
            if ((count == 0) && push) head_valid <= 1'b1;
            if ((count == 1) && pop && !push) head_valid <= 1'b0;
        end
    end

`ifdef FORMAL
    always_ff @(posedge clk) if (!reset) begin
        assert (count <= DEPTH);
        if (ddram_busy && head_valid && count != 0) begin
            assert ($stable(ddram_address));
            assert ($stable(ddram_data));
            assert ($stable(ddram_byteenable));
            assert ($stable(ddram_burstcount));
        end
    end
`endif

    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $error("daikaiju_ddram_write_fifo DEPTH must be a power of two >= 2");
    end
endmodule
