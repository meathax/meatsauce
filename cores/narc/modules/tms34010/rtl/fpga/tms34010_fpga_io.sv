// -----------------------------------------------------------------------------
// tms34010_fpga_io.sv
//
// Top-level-only pad adapter for the split tms34010_pin_system boundary.
// Cyclone V implements tri-state only in the IOE, so every Z assignment is
// isolated here. Functional video sync intervals are active high internally
// and are inverted onto the original active-low bidirectional pins. Functional
// blank is likewise inverted onto the original active-low BLANK output.
//
// Spec sources:
//   1988 TI TMS34010 User's Guide §2.4 and §9.9;
//   SPVS002C pin descriptions and local/host bus timing.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_fpga_io (
  inout  wire  [15:0] hd_io,
  output logic [15:0] hd_i_o,
  input  logic [15:0] hd_o_i,
  input  logic [1:0]  hd_oe_i,

  inout  wire  [15:0] lad_io,
  output logic [15:0] lad_i_o,
  input  logic [15:0] lad_o_i,
  input  logic        lad_oe_i,

  inout  wire         hsync_n_io,
  inout  wire         vsync_n_io,
  output logic        hsync_n_i_o,
  output logic        vsync_n_i_o,
  input  logic        hsync_i,
  input  logic        vsync_i,
  input  logic        hsync_oe_i,
  input  logic        vsync_oe_i,
  input  logic        blank_i,
  output logic        blank_n_o,

  inout  wire         ras_n_io,
  inout  wire         lal_n_io,
  inout  wire         cas_n_io,
  inout  wire         we_n_io,
  inout  wire         tr_qe_n_io,
  inout  wire         den_n_io,
  inout  wire         ddout_io,
  input  logic        ras_n_i,
  input  logic        lal_n_i,
  input  logic        cas_n_i,
  input  logic        we_n_i,
  input  logic        tr_qe_n_i,
  input  logic        den_n_i,
  input  logic        ddout_i,
  input  logic        ras_oe_i,
  input  logic        lal_oe_i,
  input  logic        cas_oe_i,
  input  logic        we_oe_i,
  input  logic        tr_qe_oe_i,
  input  logic        den_oe_i,
  input  logic        ddout_oe_i
);

  assign hd_i_o       = hd_io;
  assign hd_io[7:0]   = hd_oe_i[0] ? hd_o_i[7:0]  : 8'bz;
  assign hd_io[15:8]  = hd_oe_i[1] ? hd_o_i[15:8] : 8'bz;

  assign lad_i_o      = lad_io;
  assign lad_io       = lad_oe_i ? lad_o_i : 16'bz;

  assign hsync_n_i_o  = hsync_n_io;
  assign vsync_n_i_o  = vsync_n_io;
  assign hsync_n_io   = hsync_oe_i ? !hsync_i : 1'bz;
  assign vsync_n_io   = vsync_oe_i ? !vsync_i : 1'bz;
  assign blank_n_o    = !blank_i;

  assign ras_n_io     = ras_oe_i    ? ras_n_i   : 1'bz;
  assign lal_n_io     = lal_oe_i    ? lal_n_i   : 1'bz;
  assign cas_n_io     = cas_oe_i    ? cas_n_i   : 1'bz;
  assign we_n_io      = we_oe_i     ? we_n_i    : 1'bz;
  assign tr_qe_n_io   = tr_qe_oe_i  ? tr_qe_n_i : 1'bz;
  assign den_n_io     = den_oe_i    ? den_n_i   : 1'bz;
  assign ddout_io     = ddout_oe_i  ? ddout_i   : 1'bz;

endmodule : tms34010_fpga_io

`default_nettype wire
