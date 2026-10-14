//------------------------------------------------------------------------------
// 64 KB shared RAM between the 68000 and the H8/3002: true dual port, 32K x 16
// with byte enables (one byte-wide RAM per lane, Quartus true-dual-port
// template: each port reads or writes in a cycle). Each side has a
// level-request/one-cycle-ack port; a request is served the clock after it
// rises (read data on the ack clock).
//------------------------------------------------------------------------------
`default_nettype none

module shared_ram (
    input  logic        clk,
    input  logic        reset,
    // port A (68000)
    input  logic [15:1] a_addr,
    input  logic        a_req,
    input  logic  [1:0] a_we,
    input  logic [15:0] a_wdata,
    output logic [15:0] a_q,
    output logic        a_ack,
    // port B (H8)
    input  logic [15:1] b_addr,
    input  logic        b_req,
    input  logic  [1:0] b_we,
    input  logic [15:0] b_wdata,
    output logic [15:0] b_q,
    output logic        b_ack
);
    logic [7:0] mem_hi [32768];
    logic [7:0] mem_lo [32768];

    // one-cycle ack after the request rises, once per request
    logic a_busy, b_busy;
    wire  a_go = a_req & ~a_busy;
    wire  b_go = b_req & ~b_busy;
    always_ff @(posedge clk) begin
        if (reset) begin a_busy <= 1'b0; b_busy <= 1'b0; a_ack <= 1'b0; b_ack <= 1'b0; end
        else begin
            a_ack <= a_go;
            b_ack <= b_go;
            if (a_go) a_busy <= 1'b1; else if (!a_req) a_busy <= 1'b0;
            if (b_go) b_busy <= 1'b1; else if (!b_req) b_busy <= 1'b0;
        end
    end

    // port A
    always_ff @(posedge clk) begin
        if (a_go && a_we[1]) begin mem_hi[a_addr] <= a_wdata[15:8]; a_q[15:8] <= a_wdata[15:8]; end
        else a_q[15:8] <= mem_hi[a_addr];
    end
    always_ff @(posedge clk) begin
        if (a_go && a_we[0]) begin mem_lo[a_addr] <= a_wdata[7:0]; a_q[7:0] <= a_wdata[7:0]; end
        else a_q[7:0] <= mem_lo[a_addr];
    end
    // port B
    always_ff @(posedge clk) begin
        if (b_go && b_we[1]) begin mem_hi[b_addr] <= b_wdata[15:8]; b_q[15:8] <= b_wdata[15:8]; end
        else b_q[15:8] <= mem_hi[b_addr];
    end
    always_ff @(posedge clk) begin
        if (b_go && b_we[0]) begin mem_lo[b_addr] <= b_wdata[7:0]; b_q[7:0] <= b_wdata[7:0]; end
        else b_q[7:0] <= mem_lo[b_addr];
    end
endmodule
