// -----------------------------------------------------------------------------
// exterm_clut.sv -- colour look-up table, 2K x 16 (xRGB-1555: R=[14:10] G=[9:5] B=[4:0]).
//   CPU port  : pal_we/pal_addr/pal_wdata/pal_be write; pal_rdata = RAM[pal_addr]
//               one clk later (registered read, new data on read-during-write).
//   Scan port : scan_addr -> scan_data one clk later.
// Requires exterm_dpram_be (rtl/video/exterm_vram.sv).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
`default_nettype none
module exterm_clut (
  input  wire        clk,
  input  wire        pal_we,
  input  wire [10:0] pal_addr,
  input  wire [15:0] pal_wdata,
  input  wire [1:0]  pal_be,
  output wire [15:0] pal_rdata,
  input  wire [10:0] scan_addr,
  output wire [15:0] scan_data
);
  exterm_dpram_be #(.AW(11)) u_ram (
    .clk(clk),
    .addr_a(pal_addr), .din_a(pal_wdata), .we_a(pal_we), .be_a(pal_be), .q_a(pal_rdata),
    .addr_b(scan_addr), .q_b(scan_data)
  );
endmodule
`default_nettype wire
