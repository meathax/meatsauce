//============================================================================
// Inferred block RAM primitives.
//
// Plain synchronous-read templates that Quartus maps onto Cyclone V M10K and
// that Verilator simulates directly (unlike the altsyncram megafunction wrapper
// this replaces). Read data appears one clock after the address.
//
// The whole Yellow Cab ROM set is ~168 KB against ~696 KB of M10K on a
// 5CSEBA6, so every region lives here and the core needs no SDRAM at all.
//============================================================================

// True dual-port: independent read/write on both ports, one clock domain.
module bram_tdp #(
  parameter DW = 8,
  parameter AW = 12
) (
  input                 clk,

  input        [AW-1:0] a_addr,
  input        [DW-1:0] a_din,
  input                 a_we,
  output reg   [DW-1:0] a_dout,

  input        [AW-1:0] b_addr,
  input        [DW-1:0] b_din,
  input                 b_we,
  output reg   [DW-1:0] b_dout
);

reg [DW-1:0] mem [0:(1<<AW)-1];

`ifdef SIM_CLEAR_RAM
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif

always @(posedge clk) begin
  if (a_we) mem[a_addr] <= a_din;
  a_dout <= mem[a_addr];
end

always @(posedge clk) begin
  if (b_we) mem[b_addr] <= b_din;
  b_dout <= mem[b_addr];
end

endmodule


// Simple dual-port: one write port (ioctl download), one read port.
module bram_sdp #(
  parameter DW = 8,
  parameter AW = 12
) (
  input                 clk,

  input        [AW-1:0] wr_addr,
  input        [DW-1:0] wr_din,
  input                 wr_en,

  input        [AW-1:0] rd_addr,
  output reg   [DW-1:0] rd_dout
);

reg [DW-1:0] mem [0:(1<<AW)-1];

`ifdef SIM_CLEAR_RAM
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif

always @(posedge clk) begin
  if (wr_en) mem[wr_addr] <= wr_din;
  rd_dout <= mem[rd_addr];
end

endmodule


// Single-port RAM with synchronous read (CPU work RAM).
module bram_sp #(
  parameter DW = 8,
  parameter AW = 12
) (
  input                 clk,
  input        [AW-1:0] addr,
  input        [DW-1:0] din,
  input                 we,
  output reg   [DW-1:0] dout
);

reg [DW-1:0] mem [0:(1<<AW)-1];

`ifdef SIM_CLEAR_RAM
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif

always @(posedge clk) begin
  if (we) mem[addr] <= din;
  dout <= mem[addr];
end

endmodule
