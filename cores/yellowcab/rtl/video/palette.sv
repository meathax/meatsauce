// PROM palette → RGB (liberate_palette — MAME resistor weights)
module palette (
  input             clk,
  input             prom_wr,
  input       [4:0] prom_addr,
  input       [7:0] prom_data,

  input       [5:0] pen,       // 0-32 (32=black)
  output reg  [3:0] red,
  output reg  [3:0] green,
  output reg  [3:0] blue
);

reg [7:0] prom [0:31];

always @(posedge clk) begin
  if (prom_wr)
    prom[prom_addr] <= prom_data;
end

wire [7:0] p = (pen >= 6'd32) ? 8'h00 : prom[pen[4:0]];

// MAME liberate_palette: R/G = 0x21*b0+0x47*b1+0x97*b2; B = 0x52*b0+0xad*b1
wire [7:0] r8 = 8'(8'd33 * p[0] + 8'd71 * p[1] + 8'd151 * p[2]);
wire [7:0] g8 = 8'(8'd33 * p[3] + 8'd71 * p[4] + 8'd151 * p[5]);
wire [7:0] b8 = 8'(8'd82 * p[6] + 8'd173 * p[7]);

always @* begin
  if (pen >= 6'd32) begin
    red = 4'd0; green = 4'd0; blue = 4'd0;
  end else begin
    red   = r8[7:4];
    green = g8[7:4];
    blue  = b8[7:4];
  end
end

endmodule
