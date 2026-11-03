//============================================================================
// Block RAM primitives.
//
// Quartus uses an explicit M10K implementation for true dual-port storage so
// it cannot duplicate a complete memory for the second read port. Simulation
// retains the equivalent behavioral synchronous-read model. Simple and
// single-port memories remain inferred. Read data appears after one clock.
//============================================================================

// True dual-port: independent read/write on both ports, one clock domain.
module bram_tdp #(
  parameter DW = 8,
  parameter AW = 12,
  parameter DEPTH = (1 << AW)
) (
  input                 clk,

  input        [AW-1:0] a_addr,
  input        [DW-1:0] a_din,
  input                 a_we,
  output wire  [DW-1:0] a_dout,

  input        [AW-1:0] b_addr,
  input        [DW-1:0] b_din,
  input                 b_we,
  output wire  [DW-1:0] b_dout
);

`ifdef DELU_QUARTUS
// Do not infer this shape. Quartus 17 implements the two reads from the
// behavioral template as two complete memories for many of the large ROMs.
// The explicit bidirectional dual-port primitive supplies both registered
// read ports from one physical M10K bank.
altsyncram mem_i (
  .address_a(a_addr), .address_b(b_addr),
  .clock0(clk), .clock1(1'b1),
  .data_a(a_din), .data_b(b_din),
  .wren_a(a_we), .wren_b(b_we),
  .q_a(a_dout), .q_b(b_dout),
  .aclr0(1'b0), .aclr1(1'b0),
  .addressstall_a(1'b0), .addressstall_b(1'b0),
  .byteena_a(1'b1), .byteena_b(1'b1),
  .clocken0(1'b1), .clocken1(1'b1),
  .clocken2(1'b1), .clocken3(1'b1),
  .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
);
defparam
  mem_i.address_reg_b = "CLOCK0",
  mem_i.indata_reg_b = "CLOCK0",
  mem_i.wrcontrol_wraddress_reg_b = "CLOCK0",
  mem_i.intended_device_family = "Cyclone V",
  mem_i.lpm_type = "altsyncram",
  mem_i.numwords_a = DEPTH,
  mem_i.numwords_b = DEPTH,
  mem_i.operation_mode = "BIDIR_DUAL_PORT",
  mem_i.outdata_reg_a = "CLOCK0",
  mem_i.outdata_reg_b = "UNREGISTERED",
  mem_i.power_up_uninitialized = "FALSE",
  mem_i.read_during_write_mode_mixed_ports = "DONT_CARE",
  mem_i.read_during_write_mode_port_a = "DONT_CARE",
  mem_i.read_during_write_mode_port_b = "DONT_CARE",
  mem_i.widthad_a = AW,
  mem_i.widthad_b = AW,
  mem_i.width_a = DW,
  mem_i.width_b = DW,
  mem_i.width_byteena_a = 1,
  mem_i.width_byteena_b = 1;
`else
reg [DW-1:0] mem [0:DEPTH-1];
reg [DW-1:0] a_q, b_q;
assign a_dout = a_q;
assign b_dout = b_q;

`ifdef SIM_CLEAR_RAM
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif

always @(posedge clk) begin
  if (a_we) mem[a_addr] <= a_din;
  a_q <= mem[a_addr];
  if (b_we) mem[b_addr] <= b_din;
  b_q <= mem[b_addr];
end
`endif

endmodule


// Simple dual-port: one write port (ioctl download), one read port.
module bram_sdp #(
  parameter DW = 8,
  parameter AW = 12,
  parameter DEPTH = (1 << AW)
) (
  input                 clk,

  input        [AW-1:0] wr_addr,
  input        [DW-1:0] wr_din,
  input                 wr_en,

  input        [AW-1:0] rd_addr,
  output reg   [DW-1:0] rd_dout
);

reg [DW-1:0] mem [0:DEPTH-1];

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
  parameter AW = 12,
  parameter DEPTH = (1 << AW)
) (
  input                 clk,
  input        [AW-1:0] addr,
  input        [DW-1:0] din,
  input                 we,
  output reg   [DW-1:0] dout
);

reg [DW-1:0] mem [0:DEPTH-1];

`ifdef SIM_CLEAR_RAM
integer i;
initial for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif

always @(posedge clk) begin
  if (we) mem[addr] <= din;
  dout <= mem[addr];
end

endmodule
