// Holds stock screen_rotate write tuples until the HPS DDRAM port accepts them.
// Overflow is reported so the caller can fall back to native video.
module screen_rotate_ddr_queue #(
    parameter integer DEPTH = 64
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        frame_start,
    input  logic        source_we,
    input  logic [28:0] source_addr,
    input  logic [63:0] source_data,
    input  logic [7:0]  source_be,
    input  logic        ddram_busy,
    output logic [28:0] ddram_addr,
    output logic [63:0] ddram_data,
    output logic [7:0]  ddram_be,
    output logic        ddram_we,
    output logic        overflow
);
    localparam integer PTR_WIDTH = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam integer COUNT_WIDTH = $clog2(DEPTH + 1);

    logic [28:0] addr_mem [0:DEPTH-1];
    logic [63:0] data_mem [0:DEPTH-1];
    logic [7:0] be_mem [0:DEPTH-1];
    logic [PTR_WIDTH-1:0] wr_ptr;
    logic [PTR_WIDTH-1:0] rd_ptr;
    logic [COUNT_WIDTH-1:0] count;

    wire empty = count == 0;
    wire full = count == DEPTH;
    wire pop = !empty && !ddram_busy;
    wire push = source_we && (!full || pop);

    assign ddram_addr = empty ? 29'd0 : addr_mem[rd_ptr];
    assign ddram_data = empty ? 64'd0 : data_mem[rd_ptr];
    assign ddram_be = empty ? 8'd0 : be_mem[rd_ptr];
    assign ddram_we = !empty;

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
            overflow <= 1'b0;
        end else begin
            if (push) begin
                addr_mem[wr_ptr] <= source_addr;
                data_mem[wr_ptr] <= source_data;
                be_mem[wr_ptr] <= source_be;
                if (wr_ptr == DEPTH-1) wr_ptr <= '0;
                else wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop) begin
                if (rd_ptr == DEPTH-1) rd_ptr <= '0;
                else rd_ptr <= rd_ptr + 1'b1;
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase

            if (frame_start && empty && !source_we) overflow <= 1'b0;
            if (source_we && full && !pop) overflow <= 1'b1;
        end
    end
endmodule
