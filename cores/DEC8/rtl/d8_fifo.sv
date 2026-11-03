// Small synchronous FIFO in flops, show-ahead (q is the head while !empty).
// Used for the renderer's hit, request-tag and ROM-return queues.

module d8_fifo #(
    parameter int W = 8,
    parameter int DEPTH = 8          // power of two
) (
    input  logic         clk,
    input  logic         clr,        // synchronous flush
    input  logic         push,
    input  logic [W-1:0] d,
    input  logic         pop,
    output logic [W-1:0] q,
    output logic         empty,
    output logic         full,
    output logic [$clog2(DEPTH):0] count
);
  localparam int AW = $clog2(DEPTH);
  logic [W-1:0]  mem [0:DEPTH-1];
  logic [AW-1:0] rp, wp;

  assign q     = mem[rp];
  assign empty = count == '0;
  assign full  = count == (AW+1)'(DEPTH);

  always_ff @(posedge clk) begin
    if (clr) begin
      rp <= '0;
      wp <= '0;
      count <= '0;
    end else begin
      if (push && !full) begin
        mem[wp] <= d;
        wp <= wp + 1'b1;
      end
      if (pop && !empty) rp <= rp + 1'b1;
      case ({push && !full, pop && !empty})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase
    end
  end
endmodule
