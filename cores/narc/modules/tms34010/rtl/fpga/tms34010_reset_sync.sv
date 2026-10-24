// -----------------------------------------------------------------------------
// tms34010_reset_sync.sv
//
// Per-domain active-high reset conditioner. async_reset_i may assert at any
// phase and immediately clears the two-stage active-low release chain.
// Ones shift synchronously through both stages so active-high rst_o can only
// deassert on the destination clock. The cleared power-up value also keeps
// reset asserted on Cyclone V before the first clock edge.
//
// Downstream TMS34010 state continues to use the project's synchronous,
// active-high reset convention (A0003); only this boundary conditioner uses
// an asynchronous control so PLL loss or the board reset can assert safely.
// -----------------------------------------------------------------------------

`default_nettype none

module tms34010_reset_sync (
  input  logic clk_i,
  input  logic async_reset_i,
  output logic rst_o
);

  // Justification (reg-c): the two registers synchronize reset release into
  // this destination domain and must remain a recognizable chain.
  (* preserve, useioff = 0,
     altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION \"FORCED IF ASYNCHRONOUS\"" *)
  logic [1:0] release_n_q;

  always_ff @(posedge clk_i or posedge async_reset_i) begin
    if (async_reset_i) begin
      release_n_q <= 2'b00;
    end else begin
      release_n_q[0] <= 1'b1;
      release_n_q[1] <= release_n_q[0];
    end
  end

  assign rst_o = !release_n_q[1];

endmodule : tms34010_reset_sync

`default_nettype wire
