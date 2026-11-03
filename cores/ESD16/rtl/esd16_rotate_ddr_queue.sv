// SPDX-License-Identifier: GPL-3.0-or-later
// DDR write queue for the stock screen_rotate framebuffer writer.
// screen_rotate pulses DDRAM_WE for one clock per pixel and ignores DDRAM_BUSY, so writes issued while the
// Avalon port is busy would be lost (stale framebuffer pixels). Each write is queued here and presented
// with stable address/data/byte-enables until accepted (WE high and BUSY low).
// screen_rotate always duplicates its 32-bit pixel into both DIN halves, so only 32 data bits are stored.
// Writers produce at most one pixel per CE_PIXEL (>= 4 clocks apart); 16 entries cover long BUSY periods.
module esd16_rotate_ddr_queue #(parameter integer AW=4) (
    input  logic        clk, reset,
    input  logic        in_we,
    input  logic [28:0] in_addr,
    input  logic [31:0] in_din,
    input  logic  [7:0] in_be,
    input  logic        busy,
    output logic        out_we,
    output logic [28:0] out_addr,
    output logic [63:0] out_din,
    output logic  [7:0] out_be,
    output logic        overflow     // sticky: a write arrived while the queue was full and was dropped
);
    logic [68:0] mem [0:(1<<AW)-1];
    logic [AW:0] wr_ptr, rd_ptr;
    wire  [AW:0] used = wr_ptr - rd_ptr;
    wire         full = used[AW];
    wire         pop  = out_we && !busy;
    logic [68:0] head;

    always_ff @(posedge clk) begin
        if (in_we && !full) mem[wr_ptr[AW-1:0]] <= {in_addr, in_din, in_be};
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            wr_ptr <= '0; rd_ptr <= '0; overflow <= 1'b0;
        end else begin
            if (in_we) begin
                if (full) overflow <= 1'b1;
                else      wr_ptr <= wr_ptr + 1'd1;
            end
            if (pop) rd_ptr <= rd_ptr + 1'd1;
        end
    end

    assign head     = mem[rd_ptr[AW-1:0]];
    assign out_we   = used != '0;
    assign out_addr = head[68:40];
    assign out_din  = {head[39:8], head[39:8]};
    assign out_be   = head[7:0];
endmodule
