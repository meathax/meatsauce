// -----------------------------------------------------------------------------
// tms34010_sync_bit_ce.sv
//
// tms34010_sync_bit with a clock enable: the two stages advance only in clocks
// where ce is high. Used on the video side of the core/video crossings, so the
// same crossings work when the video logic runs on the core clock with a VCLK
// enable (VCLK_CEN=1) instead of on its own clock. With ce tied high it is
// tms34010_sync_bit.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_sync_bit_ce #(
  parameter logic RESET_VALUE = 1'b0
)(
  input  logic clk,
  input  logic rst,
  input  logic ce,
  input  logic async_i,
  output logic sync_o
);

  // As tms34010_sync_bit: the first stage absorbs metastability (when the
  // source is in another clock domain); the second is the only stage consumed.
  (* preserve, useioff = 0,
     altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION \"FORCED IF ASYNCHRONOUS\"" *)
  logic [1:0] sync_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      sync_q <= {2{RESET_VALUE}};
    end else if (ce) begin
      sync_q[0] <= async_i;
      sync_q[1] <= sync_q[0];
    end
  end

  assign sync_o = sync_q[1];

endmodule : tms34010_sync_bit_ce

`default_nettype wire
