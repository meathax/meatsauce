// -----------------------------------------------------------------------------
// dpram_tdp.sv -- true dual-port block RAM.
//
// Both ports read and write; each registers its read output (1-cycle read
// latency, write-first read-during-write on a port). The VRAM frame buffer needs
// this (port A = CPU/blitter R/W, port B = scanout read).
//
// Quartus 17.0 Standard would not infer the behavioral true-dual-port template
// (it reports "asynchronous read logic" and leaves it as registers -- the synth
// memory explosion), so for synthesis we instantiate altsyncram directly. The
// simulator (VERILATOR macro defined) takes the behavioral branch instead.
// -----------------------------------------------------------------------------

`default_nettype none
module dpram_tdp #(
  parameter int AW = 18,
  parameter int DW = 12
) (
  input  wire            clk,
  input  wire [AW-1:0]   addr_a,
  input  wire [DW-1:0]   din_a,
  input  wire            we_a,
  output wire [DW-1:0]   q_a,
  input  wire [AW-1:0]   addr_b,
  input  wire [DW-1:0]   din_b,
  input  wire            we_b,
  output wire [DW-1:0]   q_b
);
`ifdef VERILATOR
  // Behavioral true dual-port (simulation only)
  reg [DW-1:0] mem [0:(1<<AW)-1];
  reg [DW-1:0] rq_a, rq_b;
  always @(posedge clk) begin
    if (we_a) begin mem[addr_a] <= din_a; rq_a <= din_a; end
    else                                  rq_a <= mem[addr_a];
  end
  always @(posedge clk) begin
    if (we_b) begin mem[addr_b] <= din_b; rq_b <= din_b; end
    else                                  rq_b <= mem[addr_b];
  end
  assign q_a = rq_a;
  assign q_b = rq_b;
`else
  // Synthesis: explicit true dual-port M10K with registered outputs.
  altsyncram #(
    .operation_mode                    ("BIDIR_DUAL_PORT"),
    .width_a                           (DW),
    .widthad_a                         (AW),
    .numwords_a                        (1 << AW),
    .width_b                           (DW),
    .widthad_b                         (AW),
    .numwords_b                        (1 << AW),
    // UNREGISTERED q: total read latency = 1 clock (address register only),
    // exactly matching the behavioral branch above that every sim proof used.
    // With q registered (CLOCK0) reads take 2 clocks and the scanout samples
    // data mid-transition -> per-pixel-column colour striping on hardware.
    .outdata_reg_a                     ("UNREGISTERED"),
    .outdata_reg_b                     ("UNREGISTERED"),
    // Port B is single-clock too: every port-B input register must be put on
    // CLOCK0 explicitly. altsyncram's BIDIR_DUAL_PORT default is CLOCK1 --
    // which is tied off below -- so without these the scanout port's address/
    // control registers never clock on real silicon (screen stays black while
    // everything works in the behavioral sim branch above).
    .address_reg_b                     ("CLOCK0"),
    .indata_reg_b                      ("CLOCK0"),
    .wrcontrol_wraddress_reg_b         ("CLOCK0"),
    .byteena_reg_b                     ("CLOCK0"),
    .rdcontrol_reg_b                   ("CLOCK0"),
    .read_during_write_mode_port_a     ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b     ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_mixed_ports("OLD_DATA"),
    .ram_block_type                    ("M10K"),
    .intended_device_family            ("Cyclone V"),
    .power_up_uninitialized            ("TRUE"),
    .clock_enable_input_a              ("BYPASS"),
    .clock_enable_input_b              ("BYPASS"),
    .clock_enable_output_a             ("BYPASS"),
    .clock_enable_output_b             ("BYPASS"),
    .lpm_type                          ("altsyncram")
  ) u_ram (
    .clock0    (clk),
    .address_a (addr_a), .data_a (din_a), .wren_a (we_a), .q_a (q_a),
    .address_b (addr_b), .data_b (din_b), .wren_b (we_b), .q_b (q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1),
    .clocken0(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif
endmodule
`default_nettype wire
